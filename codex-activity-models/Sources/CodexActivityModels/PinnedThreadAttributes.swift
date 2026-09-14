import ActivityKit
import Foundation

public struct PinnedThreadAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var summary: String
        public var updatedAt: Date
        public init(summary: String, updatedAt: Date) { self.summary = summary; self.updatedAt = updatedAt }
    }
    public var threadId: String
    public var title: String
    public var accountScope: String
    public init(threadId: String, title: String, accountScope: String) {
        self.threadId = threadId; self.title = title; self.accountScope = accountScope
    }
}
