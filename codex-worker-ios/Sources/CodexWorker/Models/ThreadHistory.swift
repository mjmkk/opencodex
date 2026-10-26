import Foundation

/// A readable projection of one native Thread, independent of transport and storage.
public struct ThreadHistory: Equatable, Sendable {
    public struct SourceObservation: Equatable, Sendable {
        public var lastSyncedAt: String?
        public var lastCheckedAt: String?
        public var upstreamState: JSONValue?

        var isUnreachable: Bool { upstreamState?.stringValue == "unreachable" }
        var statusDescription: String {
            guard let upstreamState, upstreamState != .null else { return "未提供" }
            switch upstreamState.stringValue {
            case "unreachable": return "未连通"
            case "reachable": return "可达"
            case let state?: return state.isEmpty ? "未识别" : state
            default: return "未识别"
            }
        }
        var lastSyncedDate: Date? { Self.date(lastSyncedAt) }
        var lastCheckedDate: Date? { Self.date(lastCheckedAt) }

        private static func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")).parse(value)
        }
    }
    public struct Pagination: Equatable, Sendable {
        public var snapshot: String
        public var nextOffset: Int?
    }
    public struct Message: Equatable, Sendable {
        public var id: String
        public var role: String?
        public var text: String
        public var sentAt: Date?
        public var turnID: String? = nil
        public var phase: String? = nil
        public var turnStatus: String? = nil
        public var contextSnapshotSHA256: String? = nil
        public var hasNonemptySourceText: Bool? = nil
    }
    public struct Record: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var observedAt: String?
    }
    public struct Attachment: Identifiable, Equatable, Sendable {
        public var id: String
        public var filename: String
        public var availability: String
    }
    public var threadIdentity: String
    public var messages: [Message]
    public var records: [Record]
    public var attachments: [Attachment]
    public var downloadedAt: Date
    public var isPartial: Bool
    public var hasMore: Bool
    public var availableMessageCount: Int
    public var refreshRequested: Bool
    // Retain the immutable source checkpoint when asynchronous readers publish history.
    public var pagination: Pagination? = nil
    // Source observations describe the saved snapshot, independently of the phone's read time.
    public var sourceObservation: SourceObservation? = nil
}
