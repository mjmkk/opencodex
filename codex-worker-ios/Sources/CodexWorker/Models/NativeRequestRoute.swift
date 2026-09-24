import Foundation

/// A location, never an authorization or an owner socket supplied by the phone.
public struct NativeRequestRoute: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var receiptID: String
    /// Canonical JSON preserves 0 versus "0" and 64-bit integer IDs.
    public var requestIDJSON: String
    public var threadID: String
    public var turnID: String
    public var id: String { receiptID + ":" + requestIDJSON }

    public init?(url: URL) {
        guard url.scheme == "opencodex", url.host == "native-request",
              url.pathComponents.count == 2,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count else { return nil }
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        guard let rawID = value("requestId"), let data = rawID.data(using: .utf8),
              let requestID = try? JSONDecoder().decode(JSONValue.self, from: data),
              let thread = value("threadId"), let turn = value("turnId"),
              !thread.isEmpty, !turn.isEmpty, thread.count < 256, turn.count < 256,
              !url.lastPathComponent.isEmpty, url.lastPathComponent.count < 512 else { return nil }
        switch requestID { case .int, .string: break; default: return nil }
        self.receiptID = url.lastPathComponent
        self.requestIDJSON = requestID.nativeJSON
        self.threadID = thread; self.turnID = turn
    }

    init?(item: NativeRemoteRequest) {
        guard let turn = item.turn_id else { return nil }
        switch item.request_id { case .int, .string: break; default: return nil }
        receiptID = item.receipt_id; requestIDJSON = item.request_id.nativeJSON
        threadID = item.thread_id; turnID = turn
    }

    var selection: NativeRequestSelection? {
        guard let id = try? JSONDecoder().decode(JSONValue.self, from: Data(requestIDJSON.utf8)) else { return nil }
        return .init(receipt_id: receiptID, request_id: id, request_version: nil)
    }

    func matches(_ item: NativeRemoteRequest) -> Bool {
        item.receipt_id == receiptID && item.request_id.nativeJSON == requestIDJSON &&
            item.thread_id == threadID && item.turn_id == turnID
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "opencodex"; components.host = "native-request"
        components.path = "/" + receiptID
        components.queryItems = [.init(name: "requestId", value: requestIDJSON),
                                .init(name: "threadId", value: threadID), .init(name: "turnId", value: turnID)]
        return components.url
    }
}

struct NativeRequestRecord: Codable, Equatable, Sendable, Identifiable {
    var item: NativeRemoteRequest
    var observedAt: Date
    var id: String { item.id }
}

/// Locally retained user input and write facts; it does not create requests or retry them.
struct NativeRequestDraft: Codable, Equatable, Sendable {
    var requestVersion: String?
    var confirmationContext: JSONValue? = nil
    var content: [String: JSONValue] = [:]
    var answers: [String: String] = [:]
    var proposed: JSONValue?
    var attemptedResponse: JSONValue?
    var responseSubmitted = false
}
