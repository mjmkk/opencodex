import Foundation

struct GoalOverviewCacheEntry: Codable, Sendable {
    let payload: JSONValue
    /// Receipt time is never substituted for source coverage or evaluation time.
    let receivedAt: Date
}
