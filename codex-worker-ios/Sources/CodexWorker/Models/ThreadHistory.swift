import Foundation

/// A readable projection of one native Thread, independent of transport and storage.
public struct ThreadHistory: Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public var id: String
        public var role: String?
        public var text: String
        public var sentAt: Date?
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
}
