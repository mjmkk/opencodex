import Foundation

/// Display values supplied by the observer, never inferred from Thread activity.
struct GoalOverviewRow: Identifiable, Equatable, Sendable {
    let id: String
    let issueIdentifier: String?
    let title: String
    let issueURL: URL?
    let project: String?
    let progress: Int?
    let health: GoalHealth?
    let availability: ObservationAvailability
    let coverageAt: Date?
    let evaluatedAt: Date?
    let explanation: String?
    let obligations: [GoalOverviewRow]
    let workers: [GoalWorkerPresentation]
    var sourceNotes: [String] = []

    var validProgress: Int? {
        guard availability == .current || availability == .lastKnown else { return nil }
        return progress.flatMap { (0...100).contains($0) ? $0 : nil }
    }
    var visibleHealth: GoalHealth? {
        availability == .current || availability == .lastKnown ? health : nil
    }
}

enum GoalHealth: String, Equatable, Sendable {
    case onTrack = "On track"
    case atRisk = "At risk"
    case blocked = "Blocked"
}

/// Availability is separate from business health; missing observations have no score.
enum ObservationAvailability: Equatable, Sendable {
    case current, pending, lastKnown, failed
}

struct GoalWorkerPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let host: String?
    let state: String?
    var observedAt: Date? = nil
}

enum GoalOverviewFilter: String, CaseIterable {
    case all = "All", risk = "Risk", blocked = "Blocked"

    func includes(_ row: GoalOverviewRow) -> Bool {
        switch self {
        case .all: return true
        case .risk: return row.visibleHealth == .atRisk
        case .blocked: return row.visibleHealth == .blocked
        }
    }
}
