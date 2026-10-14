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
        _ = try inventoryValidation(payload, cached: cached)
        let result = try goals.map { try row($0, cached: cached) }
        guard Set(result.map(\.id)).count == result.count else { throw CodexError.invalidState }
        return result
    }

    /// Absent legacy metadata is unknown. Presence never falls back to a success label.
    static func inventoryValidation(_ payload: JSONValue, cached: Bool = false) throws -> GoalInventoryValidation {
        guard let root = payload.objectValue else { throw CodexError.invalidState }
        guard let raw = root["inventory_validation"] else { return .unknown }
        guard let fields = raw.objectValue,
              Set(fields.keys) == ["availability", "verified_at", "unavailability_reason"],
              let text = fields["availability"]?.stringValue,
              let state = GoalInventoryValidation.Availability(rawValue: text),
              validReason(fields["unavailability_reason"]),
              fields["verified_at"] == .null || inventoryDate(fields["verified_at"]) != nil
        else { throw CodexError.invalidState }
        let verifiedAt = inventoryDate(fields["verified_at"])
        switch state {
        case .current:
            guard let verifiedAt, verifiedAt == date(root["inventory_observed_at"]),
                  fields["unavailability_reason"] == .null else { throw CodexError.invalidState }
        case .lastKnown:
            if let verifiedAt {
                guard let observedAt = date(root["inventory_observed_at"]), verifiedAt <= observedAt else { throw CodexError.invalidState }
            }
        case .unknown:
            guard verifiedAt == nil else { throw CodexError.invalidState }
        }
        return GoalInventoryValidation(availability: cached && state == .current ? .lastKnown : state,
            verifiedAt: verifiedAt, explanation: fields["unavailability_reason"]?.stringValue)
    }

    private static func inventoryDate(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              text.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})$", options: .regularExpression) != nil
        else { return nil }
        guard let parsed = date(value) else { return nil }
        var offset = 0
        if !text.hasSuffix("Z") {
            let zone = text.suffix(6)
            let parts = zone.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] <= 23, parts[1] <= 59 else { return nil }
            offset = (parts[0] * 3600 + parts[1] * 60) * (zone.first == "+" ? 1 : -1)
        }
        let expected = text.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
            from: parsed.addingTimeInterval(TimeInterval(offset)))
        // ISO8601DateFormatter normalizes impossible dates such as February 30.
        guard [actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second].compactMap({ $0 }) == expected else { return nil }
        return parsed
    }

    private static func row(_ value: JSONValue, cached: Bool) throws -> GoalOverviewRow {
        guard let goal = value.objectValue,
              let id = goal["issue_id"]?.stringValue, !id.isEmpty,
              goal["goal_id"]?.stringValue == id,
              let title = goal["title"]?.stringValue, !title.isEmpty,
              let availability = goal["availability"]?.stringValue,
              ["current", "pending", "last_known", "partial"].contains(availability)
        else { throw CodexError.invalidState }
        guard let obligations = goal["closure_obligations"]?.arrayValue,
              let workers = goal["workers"]?.arrayValue else { throw CodexError.invalidState }
        let scope = try closureScope(goal["closure_scope"], issueURL: goal["issue_url"])
        let observation = goal["observation"]?.objectValue
        guard goal["observation"] == .null || observation != nil else { throw CodexError.invalidState }
        let progress = goal["progress"]?.intValue
        if let progress {
            guard (0...100).contains(progress) else { throw CodexError.invalidState }
        } else if goal["progress"] != .null { throw CodexError.invalidState }
        let health = goal["health"]?.stringValue.flatMap(GoalHealth.init(rawValue:))
        guard health != nil || goal["health"] == .null else { throw CodexError.invalidState }
        let progressDimension: GoalOverviewDimension?
        let healthDimension: GoalOverviewDimension?
        let state: ObservationAvailability
        // Presence is authoritative: a malformed new result must never use legacy values.
        if let raw = goal["dimensions"] {
            guard let dimensions = raw.objectValue, Set(dimensions.keys) == ["Progress", "Health"],
                  validReason(goal["unavailability_reason"]) else { throw CodexError.invalidState }
            let p = try dimension(dimensions["Progress"], value: goal["progress"], isProgress: true)
            let h = try dimension(dimensions["Health"], value: goal["health"], isProgress: false)
            let wireState = aggregate(p.availability, h.availability)
            guard wireState == availabilityState(availability),
                  (wireState == .current) == (goal["unavailability_reason"] == .null) else { throw CodexError.invalidState }
            // The backend exposes a common observation only for identical full metadata.
            let pMetadata = commonMetadata(p.observation)
            let hMetadata = commonMetadata(h.observation)
            let common: JSONValue = [.current, .lastKnown].contains(wireState) && pMetadata != nil && pMetadata == hMetadata
                ? pMetadata! : .null
            guard goal["observation"] == common else { throw CodexError.invalidState }
            progressDimension = restored(p, cached: cached)
            healthDimension = restored(h, cached: cached)
            state = aggregate(progressDimension!.availability, healthDimension!.availability)
        } else {
            guard availability != "partial" else { throw CodexError.invalidState }
            if availability == "pending" {
                guard goal["progress"] == .null, goal["health"] == .null,
                      goal["observation"] == .null else { throw CodexError.invalidState }
            } else {
                guard health != nil, let observation, date(observation["evaluated_at"]) != nil,
                      nonempty(observation["input_version"]), nonempty(observation["method_version"]) else { throw CodexError.invalidState }
            }
            state = availability == "pending" ? .pending : (cached || availability == "last_known" ? .lastKnown : .current)
            progressDimension = nil; healthDimension = nil
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
            }, sourceNotes: sourceNotes(observation), progressDimension: progressDimension, healthDimension: healthDimension,
            closureScopeDescription: scope?.description, closureScopeSourceURL: scope?.sourceURL,
            closureScopeMetadata: scope?.metadata)
    }

    /// A supplied scope is a source projection, never an inferred Issue relationship.
    private static func closureScope(_ raw: JSONValue?, issueURL: JSONValue?) throws -> (description: String, sourceURL: URL, metadata: JSONValue)? {
        guard let raw else { return nil }
        guard let fields = raw.objectValue,
              Set(fields.keys) == ["description", "source_url", "call_id", "parent_call_id"],
              fields.values.allSatisfy(nonempty),
              let description = fields["description"]?.stringValue,
              let call = fields["call_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let parent = fields["parent_call_id"]?.stringValue.flatMap(UUID.init(uuidString:)), call != parent,
              let source = fields["source_url"]?.stringValue,
              var components = scopeURLComponents(source),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, let url = components.url,
              let fragment = components.percentEncodedFragment, fragment.hasPrefix("comment-"),
              UUID(uuidString: String(fragment.dropFirst("comment-".count))) != nil,
              let issue = issueURL?.stringValue,
              var original = scopeURLComponents(issue),
              original.scheme?.lowercased() == "https", let originalHost = original.host, !originalHost.isEmpty,
              original.user == nil, original.password == nil
        else { throw CodexError.invalidState }
        components.fragment = nil; original.fragment = nil
        components.scheme = "https"; original.scheme = "https"
        components.host = host.lowercased(); original.host = originalHost.lowercased()
        if components.port == 443 { components.port = nil }
        if original.port == 443 { original.port = nil }
        guard let base = components.url, let issueBase = original.url,
              canonicalScopeBase(base) == canonicalScopeBase(issueBase) else { throw CodexError.invalidState }
        return (description, url, raw)
    }

    private static func canonicalScopeBase(_ url: URL) -> String {
        let source = url.absoluteString
        var result = "", cursor = source.startIndex
        while let range = source.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression, range: cursor..<source.endIndex) {
            result += source[cursor..<range.lowerBound]
            result += source[range].uppercased()
            cursor = range.upperBound
        }
        result += source[cursor...]
        return result
    }

    private static func scopeURLComponents(_ source: String) -> URLComponents? {
        let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard source.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              source.unicodeScalars.allSatisfy({ $0.value >= 128 || ascii.contains($0) }),
              source.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil else { return nil }
        // Source Issue URLs contain real Unicode slugs; Foundation normalizes those IRIs.
        // Reject malformed ASCII before permitting that normalization.
        return URLComponents(string: source)
    }

    private static func dimension(_ raw: JSONValue?, value: JSONValue?, isProgress: Bool) throws -> GoalOverviewDimension {
        guard let fields = raw?.objectValue,
              Set(fields.keys) == ["availability", "value", "unavailability_reason", "observation"],
              fields["value"] == value,
              let availability = fields["availability"]?.stringValue,
              ["current", "pending", "last_known", "not_applicable"].contains(availability),
              validReason(fields["unavailability_reason"]) else { throw CodexError.invalidState }
        let state = availabilityState(availability)
        if state == .pending {
            guard value == .null, fields["observation"] == .null,
                  fields["unavailability_reason"] != .null else { throw CodexError.invalidState }
            return GoalOverviewDimension(availability: state, observation: nil, coverageAt: nil, evaluatedAt: nil,
                explanation: fields["unavailability_reason"]?.stringValue, notApplicable: false, sourceNotes: [])
        }
        guard let metadata = fields["observation"]?.objectValue,
              metadata["value"] == nil,
              ["input_version", "goal_version", "method_version"].allSatisfy({ nonempty(metadata[$0]) }),
              let evaluatedAt = date(metadata["evaluated_at"]),
              metadata["input_coverage_at"] == .null || date(metadata["input_coverage_at"]) != nil,
              let sources = metadata["sources"]?.arrayValue, sources.allSatisfy({ $0.objectValue != nil }) else { throw CodexError.invalidState }
        let notApplicable = metadata["not_applicable"] == .bool(true)
        guard metadata["not_applicable"] == nil || notApplicable else { throw CodexError.invalidState }
        if isProgress {
            if value == .null {
                guard notApplicable, metadata["completion_scope"] == .string("unbounded"),
                      [.notApplicable, .lastKnown].contains(state) else { throw CodexError.invalidState }
            } else {
                guard let number = value?.intValue, (0...100).contains(number), !notApplicable,
                      state != .notApplicable else { throw CodexError.invalidState }
            }
        } else {
            guard let text = value?.stringValue, GoalHealth(rawValue: text) != nil,
                  state != .notApplicable, !notApplicable else { throw CodexError.invalidState }
        }
        guard state != .current || fields["unavailability_reason"] == .null,
              state != .lastKnown || fields["unavailability_reason"] != .null,
              state != .notApplicable || fields["unavailability_reason"] == .string("unbounded_goal") else { throw CodexError.invalidState }
        return GoalOverviewDimension(availability: state, observation: fields["observation"],
            coverageAt: date(metadata["input_coverage_at"]), evaluatedAt: evaluatedAt,
            explanation: fields["unavailability_reason"]?.stringValue, notApplicable: notApplicable,
            sourceNotes: sourceNotes(metadata))
    }

    private static func aggregate(_ progress: ObservationAvailability, _ health: ObservationAvailability) -> ObservationAvailability {
        if progress == .pending && health == .pending { return .pending }
        if [.current, .notApplicable].contains(progress) && health == .current { return .current }
        if progress == .lastKnown && health == .lastKnown { return .lastKnown }
        return .partial
    }

    private static func availabilityState(_ value: String) -> ObservationAvailability {
        switch value {
        case "current": return .current
        case "last_known": return .lastKnown
        case "partial": return .partial
        case "not_applicable": return .notApplicable
        default: return .pending
        }
    }

    private static func restored(_ dimension: GoalOverviewDimension, cached: Bool) -> GoalOverviewDimension {
        guard cached, [.current, .notApplicable].contains(dimension.availability) else { return dimension }
        return GoalOverviewDimension(availability: .lastKnown, observation: dimension.observation,
            coverageAt: dimension.coverageAt, evaluatedAt: dimension.evaluatedAt, explanation: dimension.explanation,
            notApplicable: dimension.notApplicable, sourceNotes: dimension.sourceNotes)
    }

    private static func commonMetadata(_ value: JSONValue?) -> JSONValue? {
        guard var fields = value?.objectValue else { return nil }
        fields.removeValue(forKey: "not_applicable")
        return .object(fields)
    }

    private static func validReason(_ value: JSONValue?) -> Bool { value == .null || nonempty(value) }
    private static func nonempty(_ value: JSONValue?) -> Bool { !(value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    private static func sourceNotes(_ observation: [String: JSONValue]?) -> [String] {
        (observation?["sources"]?.arrayValue ?? []).compactMap { source in
            guard let fields = source.objectValue else { return nil }
            return ["source_type", "source_id", "source_revision", "memory_revision", "coverage", "covered_at"]
                .map { key in key + ": " + description(fields[key]) }.joined(separator: " · ")
        }
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
