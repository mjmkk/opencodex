import CryptoKit
import Foundation

struct NotificationApprovalIntent: Equatable, Sendable {
    let id: String
    let version: String
    let clientScope: String
    let value: String

    init?(info: [String: String], action: String) {
        guard info["source"] == "structured_approval",
              let id = info["approvalId"], !id.isEmpty, id.count < 256,
              let version = info["requestVersion"], !version.isEmpty,
              let clientScope = info["clientScope"], !clientScope.isEmpty,
              ["AGT_APPROVE", "AGT_REJECT"].contains(action) else { return nil }
        self.id = id; self.version = version; self.clientScope = clientScope
        value = action == "AGT_APPROVE" ? "approve" : "reject"
    }

    func submission(document: MobileApproval, expectedClientScope: String) throws -> MobileApprovalSubmission {
        guard clientScope == expectedClientScope, document.id == id, document.request_version == version,
              document.quick_response?["kind"]?.stringValue == "approve_reject",
              document.request["risk"]?.stringValue == "ordinary",
              document.schema["kind"]?.stringValue == "approve_reject",
              document.state == "pending" && !document.expired ||
                document.state == "answered" && document.response == .string(value) else { throw CodexError.invalidState }
        let bytes = try JSONEncoder().encode([clientScope, id, version, value])
        let nonce = "notification:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(id: id, request_version: version, event_id: nonce, value: .string(value), notification_action: true)
    }
}

@MainActor
public enum NotificationApprovalResponder {
    /// Called only for a real, authenticated notification button response. No
    /// background refresh, launch or network retry invokes this operation.
    public static func respond(info: [String: String], action: String) async -> String {
        do {
            guard let intent = NotificationApprovalIntent(info: info, action: action),
                  RemotePushRegistrationService.matchesCurrentAccount(intent.clientScope),
                  let configuration = WorkerConfiguration.load(), let cache = MobileSyncCache.shared else {
                return "这条通知不属于当前连接，请在当前请求中重新查看。"
            }
            let scope = try MobileSyncEngine.scope()
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
            guard let id = intent.id.addingPercentEncoding(withAllowedCharacters: allowed) else { throw CodexError.invalidState }
            let document: MobileApproval = try await request(configuration, path: "/v1/approvals/\(id)")
            var answer = try intent.submission(document: document, expectedClientScope: RemotePushRegistrationService.binding(for: scope))
            guard try MobileSyncEngine.scope() == scope else { throw CodexError.invalidState }
            let (_, drafts) = try await cache.approvals(scope: scope)
            // A prior uncertain submission keeps its original immutable event ID.
            if let draft = drafts[intent.id], draft.requestVersion == intent.version, draft.value == answer.value {
                answer.event_id = draft.eventId
            }
            try await cache.saveApprovalDraft(.init(requestVersion: answer.request_version, eventId: answer.event_id, value: answer.value),
                                              id: intent.id, scope: scope)
            guard try MobileSyncEngine.scope() == scope else { throw CodexError.invalidState }
            let result: MobileApprovalList = try await request(configuration, path: "/v1/approvals/\(id)/answer", body: JSONEncoder().encode(answer))
            guard try MobileSyncEngine.scope() == scope, result.data.count == 1,
                  result.data[0].id == intent.id, result.data[0].request_version == intent.version,
                  result.data[0].state == "answered", result.data[0].response == answer.value else { throw CodexError.invalidState }
            try await cache.saveApprovals(result.data, scope: scope)
            return "服务端已确认接收，回传状态：" + result.data[0].statusText
        } catch {
            return "快捷回复尚未确认。请刷新请求核对状态；已保存的草稿不会自动补交。"
        }
    }

    private static func request<T: Decodable>(_ config: WorkerConfiguration, path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: config.baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let token = config.token, !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
