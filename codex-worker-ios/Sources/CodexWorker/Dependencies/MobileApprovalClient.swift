import ComposableArchitecture
import Foundation

public struct MobileApproval: Codable, Equatable, Sendable, Identifiable {
    public var request: [String: JSONValue]
    public var request_version: String
    public var state: String
    public var invalid_reason: String?
    public var response: JSONValue?
    public var delivery: [String: JSONValue]?
    public var id: String { request["id"]?.stringValue ?? "" }
    public var question: String { request["question"]?.stringValue ?? "待确认请求" }
    public var schema: [String: JSONValue] { request["input"]?.objectValue ?? [:] }
    public var expired: Bool { (request["expires_at"]?.doubleValue ?? 0) <= Date().timeIntervalSince1970 }
    public var batchScope: String? { request["risk"]?.stringValue == "ordinary" ? request["batch_scope"]?.stringValue : nil }
    public var statusText: String {
        if state == "invalidated" || expired && state == "pending" { return "已失效" }
        if state == "pending" { return "等待你确认" }
        switch delivery?["state"]?.stringValue {
        case "delivered": return "已回传原任务"
        case "invalidated": return "已接收，回传前失效"
        case "needs_inspection", "sending": return "已接收，回传待核对"
        default: return "已接收，等待原任务"
        }
    }
}
public struct MobileApprovalList: Codable, Equatable, Sendable { public var data: [MobileApproval] }
public struct MobileApprovalDraft: Codable, Equatable, Sendable {
    public var requestVersion: String
    public var eventId: String
    public var value: JSONValue
}
public struct MobileApprovalSubmission: Codable, Sendable {
    public var id: String
    public var request_version: String
    public var event_id: String
    public var value: JSONValue
}

public enum MobileApprovalStore {
    public static func cached() async throws -> ([MobileApproval], [String: MobileApprovalDraft]) {
        guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
        return try await cache.approvals(scope: MobileSyncEngine.scope())
    }
    public static func save(_ documents: [MobileApproval]) async throws {
        guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
        try await cache.saveApprovals(documents, scope: MobileSyncEngine.scope())
    }
    public static func saveDraft(_ draft: MobileApprovalDraft, id: String) async throws {
        guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
        try await cache.saveApprovalDraft(draft, id: id, scope: MobileSyncEngine.scope())
    }
}
