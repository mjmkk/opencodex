import Foundation

/// Validate the response before replacing the last usable snapshot.
enum GoalOverviewDecoder {
    static func rows(_ payload: JSONValue, cached: Bool = false) throws -> [GoalOverviewRow] {
        guard let root = payload.objectValue, root["ok"]?.boolValue == true,
              root["schema_version"]?.intValue == 1,
              root["source"]?.stringValue == "goal_observer",
              let goals = root["goals"]?.arrayValue else { throw CodexError.invalidState }
        guard let namespace = root["namespace"]?.stringValue, namespace.hasPrefix("openai:"),
              let revision = root["snapshot_revision"]?.intValue, revision > 0,
              date(root["inventory_observed_at"]) != nil else { throw CodexError.invalidState }
        let result = try goals.map { try row($0, cached: cached) }
        guard Set(result.map(\.id)).count == result.count else { throw CodexError.invalidState }
        return result
    }

    private static func row(_ value: JSONValue, cached: Bool) throws -> GoalOverviewRow {
        guard let goal = value.objectValue,
              let id = goal["issue_id"]?.stringValue, !id.isEmpty,
              goal["goal_id"]?.stringValue == id,
              let title = goal["title"]?.stringValue, !title.isEmpty,
              let availability = goal["availability"]?.stringValue,
              ["current", "pending", "last_known"].contains(availability)
        else { throw CodexError.invalidState }
        guard let obligations = goal["closure_obligations"]?.arrayValue,
              let workers = goal["workers"]?.arrayValue else { throw CodexError.invalidState }
        let observation = goal["observation"]?.objectValue
        let state: ObservationAvailability = availability == "pending" ? .pending :
            (cached || availability == "last_known" ? .lastKnown : .current)
        let progress = goal["progress"]?.intValue
        if let progress {
            guard (0...100).contains(progress) else { throw CodexError.invalidState }
        } else if goal["progress"] != .null { throw CodexError.invalidState }
        let health = goal["health"]?.stringValue.flatMap(GoalHealth.init(rawValue:))
        guard health != nil || goal["health"] == .null else { throw CodexError.invalidState }
        if availability != "pending" {
            guard let observation, date(observation["evaluated_at"]) != nil,
                  observation["input_version"]?.stringValue != nil,
                  observation["method_version"]?.stringValue != nil else { throw CodexError.invalidState }
        }
        if availability == "pending" {
            guard goal["progress"] == .null, goal["health"] == .null,
                  goal["observation"] == .null else { throw CodexError.invalidState }
        }
        let url = goal["issue_url"]?.stringValue.flatMap(URL.init(string:))
        return GoalOverviewRow(id: id, issueIdentifier: id, title: title,
            issueURL: url?.scheme == "https" ? url : nil,
            project: goal["project"]?.objectValue?["name"]?.stringValue,
            progress: progress, health: health, availability: state,
            coverageAt: date(observation?["input_coverage_at"]),
            evaluatedAt: date(observation?["evaluated_at"]),
            explanation: goal["unavailability_reason"]?.stringValue,
            obligations: try obligations.map { try row($0, cached: cached) },
            workers: try workers.map { worker in
                guard let fields = worker.objectValue, let thread = fields["thread_id"]?.stringValue else { throw CodexError.invalidState }
                let host = fields["host_id"]?.stringValue
                return GoalWorkerPresentation(id: (host ?? "") + ":" + thread,
                    title: fields["title"]?.stringValue ?? thread, host: host,
                    state: fields["native_status"]?.stringValue ?? "状态未知",
                    observedAt: date(fields["observed_at"]))
            }, sourceNotes: (observation?["sources"]?.arrayValue ?? []).compactMap { source in
                guard let fields = source.objectValue else { return nil }
                return ["source_type", "source_id", "source_revision", "memory_revision", "coverage", "covered_at"]
                    .map { key in key + ": " + description(fields[key]) }.joined(separator: " · ")
            })
    }

    private static func description(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "未知" }
        if let text = value.stringValue { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "未知"
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
