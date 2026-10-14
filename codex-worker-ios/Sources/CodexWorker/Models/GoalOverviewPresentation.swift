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
    var progressDimension: GoalOverviewDimension? = nil
    var healthDimension: GoalOverviewDimension? = nil
    var closureScopeDescription: String? = nil
    var closureScopeSourceURL: URL? = nil
    var closureScopeMetadata: JSONValue? = nil

    var progressAvailability: ObservationAvailability { progressDimension?.availability ?? availability }
    var healthAvailability: ObservationAvailability { healthDimension?.availability ?? availability }
    var progressNotApplicable: Bool { progress == nil && progressDimension?.notApplicable == true }

    var validProgress: Int? {
        guard progressAvailability == .current || progressAvailability == .lastKnown else { return nil }
        return progress.flatMap { (0...100).contains($0) ? $0 : nil }
    }
    var visibleHealth: GoalHealth? {
        healthAvailability == .current || healthAvailability == .lastKnown ? health : nil
    }
    var hasPendingAssessment: Bool { (validProgress == nil && !progressNotApplicable) || visibleHealth == nil }
    var hasLastKnownAssessment: Bool { progressAvailability == .lastKnown || healthAvailability == .lastKnown }
}

/// Each adopted dimension keeps its complete, original provenance independently.
struct GoalOverviewDimension: Equatable, Sendable {
    let availability: ObservationAvailability
    let observation: JSONValue?
    let coverageAt: Date?
    let evaluatedAt: Date?
    let explanation: String?
    let notApplicable: Bool
    let sourceNotes: [String]
}

enum GoalHealth: String, Equatable, Sendable {
    case onTrack = "On track"
    case atRisk = "At risk"
    case blocked = "Blocked"
}

/// Availability is separate from business health; missing observations have no score.
enum ObservationAvailability: Equatable, Sendable {
    case current, pending, lastKnown, partial, notApplicable, failed
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
