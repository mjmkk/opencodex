import Foundation
import XCTest
#if !GOAL_OVERVIEW_STANDALONE
@testable import CodexWorker
#endif

/// Synthetic wire-shape fixtures verify the client contract, never business scoring.
final class GoalOverviewDecoderTests: XCTestCase {
    func testIndependentAvailabilityAndHealthFilters() throws {
        let progressOnly = try row(goal(progress: slot("current", .int(73)), health: slot("pending", .null)))
        XCTAssertEqual(progressOnly.validProgress, 73)
        XCTAssertNil(progressOnly.visibleHealth)
        XCTAssertTrue(progressOnly.hasPendingAssessment)
        XCTAssertFalse(GoalOverviewFilter.blocked.includes(progressOnly))
        let healthOnly = try row(goal(progress: slot("pending", .null), health: slot("current", .string("Blocked"))))
        XCTAssertNil(healthOnly.validProgress)
        XCTAssertEqual(healthOnly.visibleHealth, .blocked)
        XCTAssertTrue(GoalOverviewFilter.blocked.includes(healthOnly))
        XCTAssertFalse(GoalOverviewFilter.risk.includes(healthOnly))
    }

    func testMixedTimesAndCacheRestoreStayIndependent() throws {
        let old = metadata(time: "2026-10-12T03:00:00Z", version: "fixture-old")
        let wire = goal(progress: slot("current", .int(73)), health: slot("last_known", .string("At risk"), observation: old))
        let fresh = try row(wire)
        XCTAssertEqual(fresh.availability, .partial)
        XCTAssertEqual(fresh.progressAvailability, .current)
        XCTAssertEqual(fresh.healthAvailability, .lastKnown)
        XCTAssertNil(fresh.evaluatedAt)
        XCTAssertNotEqual(fresh.progressDimension?.evaluatedAt, fresh.healthDimension?.evaluatedAt)
        XCTAssertTrue(GoalOverviewFilter.risk.includes(fresh))
        let payload = page(wire)
        let entry = GoalOverviewCacheEntry(payload: payload, receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let reopened = try JSONDecoder().decode(GoalOverviewCacheEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(reopened.payload, payload)
        let stale = try GoalOverviewDecoder.rows(reopened.payload, cached: true).first!
        XCTAssertEqual(stale.availability, .lastKnown)
        XCTAssertEqual(stale.validProgress, 73)
        XCTAssertEqual(stale.visibleHealth, .atRisk)
        XCTAssertEqual(stale.progressDimension?.observation, fresh.progressDimension?.observation)
        XCTAssertEqual(stale.healthDimension?.observation, fresh.healthDimension?.observation)
        XCTAssertEqual(stale.progressDimension?.evaluatedAt, fresh.progressDimension?.evaluatedAt)
        XCTAssertEqual(stale.healthDimension?.coverageAt, fresh.healthDimension?.coverageAt)
        let inverse = try row(goal(progress: slot("last_known", .int(37), observation: old), health: slot("current", .string("On track"))))
        XCTAssertEqual(inverse.validProgress, 37)
        XCTAssertEqual(inverse.progressAvailability, .lastKnown)
        XCTAssertEqual(inverse.healthAvailability, .current)
    }

    func testOnlyExplicitUnboundedScopeIsNotApplicable() throws {
        var unbounded = metadata().objectValue!
        unbounded["not_applicable"] = .bool(true)
        unbounded["completion_scope"] = .string("unbounded")
        let p = slot("not_applicable", .null, observation: .object(unbounded))
        let wire = goal(progress: p, health: slot("current", .string("On track")), availability: "current")
        let resolved = try row(wire)
        XCTAssertTrue(resolved.progressNotApplicable)
        XCTAssertFalse(resolved.hasPendingAssessment)
        XCTAssertNil(resolved.validProgress)
        let cached = try row(wire, cached: true)
        XCTAssertTrue(cached.progressNotApplicable)
        XCTAssertEqual(cached.progressAvailability, .lastKnown)
        XCTAssertEqual(cached.progressDimension?.observation, resolved.progressDimension?.observation)
        let unknown = try row(goal(progress: slot("pending", .null), health: slot("current", .string("On track"))))
        XCTAssertFalse(unknown.progressNotApplicable)
        unbounded["completion_scope"] = .string("unknown")
        XCTAssertThrowsError(try row(goal(progress: slot("not_applicable", .null, observation: .object(unbounded)),
            health: slot("current", .string("On track")), availability: "current")))
        XCTAssertThrowsError(try row(goal(progress: slot("current", .int(73)), health: p, availability: "current")))
    }

    func testLegacyCurrentPendingAndLastKnownRemainReadable() throws {
        var legacy = goal(progress: slot("current", .int(91)), health: slot("current", .string("Blocked")), availability: "current").objectValue!
        legacy.removeValue(forKey: "dimensions")
        legacy["observation"] = metadata()
        let current = try row(.object(legacy))
        XCTAssertEqual(current.validProgress, 91)
        XCTAssertEqual(current.visibleHealth, .blocked)
        XCTAssertNil(current.progressDimension)
        let cached = try row(.object(legacy), cached: true)
        XCTAssertEqual(cached.availability, .lastKnown)
        XCTAssertEqual(cached.evaluatedAt, current.evaluatedAt)
        legacy["availability"] = .string("last_known")
        XCTAssertEqual(try row(.object(legacy)).validProgress, 91)
        legacy["availability"] = .string("pending")
        legacy["progress"] = .null; legacy["health"] = .null; legacy["observation"] = .null
        XCTAssertNil(try row(.object(legacy)).visibleHealth)
        legacy["availability"] = .string("partial")
        XCTAssertThrowsError(try row(.object(legacy)))
    }

    func testPresentMalformedDimensionsNeverFallBack() throws {
        let valid = goal(progress: slot("current", .int(73)), health: slot("current", .string("On track")), availability: "current", observation: metadata())
        for malformed: JSONValue in [.null, .array([]), .object([:]), .object(["Progress": slot("current", .int(73))])] {
            var fields = valid.objectValue!; fields["dimensions"] = malformed
            XCTAssertThrowsError(try row(.object(fields)))
        }
        var extra = slot("current", .int(73)).objectValue!; extra["extra"] = .bool(true)
        XCTAssertThrowsError(try row(goal(progress: .object(extra), health: slot("pending", .null))))
        for malformed: JSONValue in [.string("73"), .double(73.5), .int(-1), .int(101), .bool(true)] {
            XCTAssertThrowsError(try row(goal(progress: slot("current", malformed), health: slot("pending", .null))))
        }
        var mismatch = valid.objectValue!; mismatch["progress"] = .int(74)
        XCTAssertThrowsError(try row(.object(mismatch)))
        XCTAssertThrowsError(try row(goal(progress: slot("pending", .int(0)), health: slot("pending", .null), availability: "pending")))
        XCTAssertThrowsError(try row(goal(progress: slot("current", .int(73)), health: slot("current", .string("Unknown")), availability: "current")))
    }

    func testCompleteObservationAndAggregateConsistencyAreRequired() throws {
        let valid = goal(progress: slot("current", .int(73)), health: slot("pending", .null))
        var fields = valid.objectValue!; fields["observation"] = metadata()
        XCTAssertThrowsError(try row(.object(fields)))
        fields = valid.objectValue!; fields["availability"] = .string("current"); fields["unavailability_reason"] = .null
        XCTAssertThrowsError(try row(.object(fields)))
        for key in ["goal_version", "input_version", "method_version", "evaluated_at", "input_coverage_at", "sources"] {
            var bad = metadata().objectValue!; bad.removeValue(forKey: key)
            XCTAssertThrowsError(try row(goal(progress: slot("current", .int(73), observation: .object(bad)), health: slot("pending", .null))))
        }
        var bad = metadata().objectValue!; bad["value"] = .int(73)
        XCTAssertThrowsError(try row(goal(progress: slot("current", .int(73), observation: .object(bad)), health: slot("pending", .null))))
        let old = metadata(time: "2026-10-12T03:00:00Z", version: "fixture-old")
        let separate = try row(goal(progress: slot("current", .int(73)), health: slot("current", .string("On track"), observation: old), availability: "current"))
        XCTAssertNil(separate.evaluatedAt)
        XCTAssertNotEqual(separate.progressDimension?.observation, separate.healthDimension?.observation)
        let common = try row(goal(progress: slot("current", .int(73)), health: slot("current", .string("On track")), availability: "current", observation: metadata()))
        XCTAssertNotNil(common.evaluatedAt)
    }

    func testUnknownCoverageAndFullProvenanceArePreserved() throws {
        var full = metadata().objectValue!
        full["progress_mapping"] = .object(["raw_score": .double(2.9), "mapped_progress": .int(73)])
        full["extra_provenance"] = .array([.string("Fixture only, retain full metadata")])
        let decoded = try row(goal(progress: slot("current", .int(73), observation: .object(full)), health: slot("pending", .null)))
        XCTAssertNil(decoded.progressDimension?.coverageAt)
        XCTAssertEqual(decoded.progressDimension?.observation, .object(full))
        XCTAssertEqual(decoded.progressDimension?.sourceNotes.count, 1)
        XCTAssertTrue(decoded.progressDimension!.sourceNotes[0].contains("covered_at: 未知"))
    }

    func testNestedObligationsUseTheSameIndependentContract() throws {
        var child = goal(progress: slot("pending", .null), health: slot("current", .string("At risk"))).objectValue!
        child["issue_id"] = .string("AGT-32"); child["goal_id"] = .string("AGT-32")
        var parent = goal(progress: slot("current", .int(73)), health: slot("pending", .null)).objectValue!
        parent["closure_obligations"] = .array([.object(child)])
        let decoded = try row(.object(parent))
        XCTAssertEqual(decoded.obligations.first?.visibleHealth, .atRisk)
        XCTAssertNil(decoded.obligations.first?.validProgress)
        XCTAssertEqual(decoded.validProgress, 73)
    }

    func testClosureScopeAbsentKeepsLegacyAndDimensionRowsUnchanged() throws {
        let dimensionGoal = goal(progress: slot("pending", .null), health: slot("current", .string("At risk")))
        let dimensionRow = try row(dimensionGoal)
        XCTAssertNil(dimensionRow.closureScopeDescription)
        XCTAssertNil(dimensionRow.closureScopeSourceURL)
        XCTAssertNil(dimensionRow.closureScopeMetadata)
        XCTAssertEqual(dimensionRow.issueIdentifier, "AGT-34")
        XCTAssertEqual(dimensionRow.title, dimensionGoal.objectValue?["title"]?.stringValue)
        XCTAssertEqual(dimensionRow.issueURL?.absoluteString, "https://linear.app/mjmk/issue/AGT-34")
        XCTAssertEqual(dimensionRow.progressAvailability, .pending)
        XCTAssertEqual(dimensionRow.healthAvailability, .current)
        XCTAssertEqual(dimensionRow.visibleHealth, .atRisk)

        var legacy = goal(progress: slot("current", .int(91)), health: slot("current", .string("Blocked")), availability: "current").objectValue!
        legacy.removeValue(forKey: "dimensions")
        legacy["observation"] = metadata()
        let legacyRow = try row(.object(legacy))
        XCTAssertNil(legacyRow.closureScopeMetadata)
        XCTAssertEqual(legacyRow.validProgress, 91)
        XCTAssertEqual(legacyRow.visibleHealth, .blocked)
    }

    func testClosureScopeNestedMetadataSurvivesCacheRoundtrip() throws {
        let scope = closureScope()
        var child = goal(progress: slot("pending", .null), health: slot("current", .string("At risk"))).objectValue!
        child["closure_scope"] = scope
        child["project"] = .object(["name": .string("Fixture project")])
        var parent = goal(progress: slot("current", .int(73)), health: slot("pending", .null)).objectValue!
        parent["issue_id"] = .string("AGT-12"); parent["goal_id"] = .string("AGT-12")
        parent["issue_url"] = .string("https://linear.app/mjmk/issue/AGT-12")
        parent["closure_obligations"] = .array([.object(child)])
        let payload = page(.object(parent))
        let entry = GoalOverviewCacheEntry(payload: payload, receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let reopened = try JSONDecoder().decode(GoalOverviewCacheEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(reopened.payload, payload)
        let fresh = try GoalOverviewDecoder.rows(reopened.payload).first!
        let nested = fresh.obligations.first!
        XCTAssertNil(fresh.closureScopeMetadata)
        XCTAssertEqual(nested.closureScopeMetadata, scope)
        XCTAssertEqual(nested.closureScopeDescription, scope.objectValue?["description"]?.stringValue)
        XCTAssertEqual(nested.closureScopeSourceURL?.absoluteString, scope.objectValue?["source_url"]?.stringValue)
        XCTAssertEqual(nested.project, "Fixture project")
        XCTAssertEqual(nested.issueIdentifier, "AGT-34")
        XCTAssertEqual(nested.progressAvailability, .pending)
        XCTAssertEqual(nested.healthAvailability, .current)
        XCTAssertEqual(nested.visibleHealth, .atRisk)
        XCTAssertEqual(fresh.validProgress, 73)
        let cached = try GoalOverviewDecoder.rows(reopened.payload, cached: true).first!.obligations.first!
        XCTAssertEqual(cached.closureScopeMetadata, scope)
        XCTAssertEqual(cached.healthAvailability, .lastKnown)
        XCTAssertEqual(cached.healthDimension?.observation, nested.healthDimension?.observation)
        XCTAssertEqual(cached.progressAvailability, .pending)
    }

    func testClosureScopeSourceRequiresAbsoluteHTTPSWithoutUserInfo() throws {
        var scope = closureScope().objectValue!
        let wire = goal(progress: slot("pending", .null), health: slot("current", .string("At risk")))
        for source in ["", " \n ", "http://example.com/source", "//example.com/source", "/relative", "https:relative",
            "https://", "https://user:password@example.com/source", "https://@example.com/source",
            "https://example.com/a b", "https://example.com/%GG",
            "https://linear.app/mjmk/issue/AGT-34", "https://linear.app/mjmk/issue/AGT-34#comment-not-a-uuid",
            "https://linear.app/mjmk/issue/AGT-34#comment-%66a000000-0000-4000-8000-000000000001",
            "https://linear.app/mjmk/issue/AGT-34#other-fa000000-0000-4000-8000-000000000001",
            "https://linear.app/mjmk/issue/AGT-35#comment-fa000000-0000-4000-8000-000000000001",
            "https://example.com/mjmk/issue/AGT-34#comment-fa000000-0000-4000-8000-000000000001",
            "https://linear.app/mjmk/issue/AGT-34?other=true#comment-fa000000-0000-4000-8000-000000000001"] {
            scope["source_url"] = .string(source)
            var fields = wire.objectValue!; fields["closure_scope"] = .object(scope)
            XCTAssertThrowsError(try row(.object(fields)), source)
        }
    }

    func testClosureScopeUnicodeAndPercentEscapedIssuePathsAreEquivalent() throws {
        // Frozen AGT-34 URL language sample only; the scope and Call UUIDs remain synthetic.
        let issue = "https://linear.app/mjmk/issue/AGT-34/用-jev-构建-opencodex-observeroverview通知与旁路评估"
        let encoded = URLComponents(string: issue)!.url!.absoluteString
        var lowercaseHex = encoded
        let escapes = try NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")
        for match in escapes.matches(in: encoded, range: NSRange(encoded.startIndex..., in: encoded)).reversed() {
            let range = Range(match.range, in: lowercaseHex)!
            lowercaseHex.replaceSubrange(range, with: lowercaseHex[range].lowercased())
        }
        let fragment = "#comment-fa000000-0000-4000-8000-000000000001"
        for pair in [(issue, issue), (issue, encoded), (encoded, issue), (issue, lowercaseHex),
                     (lowercaseHex, issue), (encoded, lowercaseHex), (lowercaseHex, encoded)] {
            var fields = goal(progress: slot("pending", .null), health: slot("current", .string("At risk"))).objectValue!
            fields["issue_url"] = .string(pair.0)
            var scope = closureScope().objectValue!; scope["source_url"] = .string(pair.1 + fragment)
            fields["closure_scope"] = .object(scope)
            let decoded = try row(.object(fields))
            XCTAssertEqual(decoded.closureScopeMetadata, .object(scope))
            XCTAssertEqual(decoded.issueURL, URL(string: pair.0))
            XCTAssertEqual(decoded.healthAvailability, .current)
            XCTAssertEqual(decoded.progressAvailability, .pending)
        }
        for pair in [("https://linear.app/mjmk/issue/AGT-34/part/child", "https://linear.app/mjmk/issue/AGT-34/part%2fchild"),
                     ("https://linear.app/mjmk/issue/AGT-34/part%2Fchild", "https://linear.app/mjmk/issue/AGT-34/part/child"),
                     ("https://linear.app/mjmk/issue/AGT-34/part", "https://linear.app/mjmk/issue/AGT-34/Part")] {
            var fields = goal(progress: slot("pending", .null), health: slot("current", .string("At risk"))).objectValue!
            fields["issue_url"] = .string(pair.0)
            var scope = closureScope().objectValue!; scope["source_url"] = .string(pair.1 + fragment)
            fields["closure_scope"] = .object(scope)
            XCTAssertThrowsError(try row(.object(fields)), "Reserved slash and path case must retain their meaning")
        }
    }

    func testClosureScopePresentMalformedShapeAndTextAreRejected() throws {
        let wire = goal(progress: slot("pending", .null), health: slot("current", .string("At risk")))
        for malformed: JSONValue in [.null, .bool(true), .string("Fixture scope"), .array([]), .object([:])] {
            var fields = wire.objectValue!; fields["closure_scope"] = malformed
            XCTAssertThrowsError(try row(.object(fields)))
        }
        for key in ["description", "source_url", "call_id", "parent_call_id"] {
            var scope = closureScope().objectValue!; scope.removeValue(forKey: key)
            var fields = wire.objectValue!; fields["closure_scope"] = .object(scope)
            XCTAssertThrowsError(try row(.object(fields)), "missing \(key)")
            for invalid: JSONValue in [.null, .int(1), .bool(false), .string(""), .string(" \n\t ")] {
                scope = closureScope().objectValue!; scope[key] = invalid
                fields["closure_scope"] = .object(scope)
                XCTAssertThrowsError(try row(.object(fields)), "invalid \(key)")
            }
        }
        var extra = closureScope().objectValue!; extra["extra"] = .string("Fixture only")
        var fields = wire.objectValue!; fields["closure_scope"] = .object(extra)
        XCTAssertThrowsError(try row(.object(fields)))
        for key in ["call_id", "parent_call_id"] {
            var scope = closureScope().objectValue!; scope[key] = .string("fixture-not-a-uuid")
            fields["closure_scope"] = .object(scope)
            XCTAssertThrowsError(try row(.object(fields)), "bad UUID \(key)")
        }
        for sameParent in ["fa000000-0000-4000-8000-000000000034", "FA000000-0000-4000-8000-000000000034"] {
            var scope = closureScope().objectValue!; scope["parent_call_id"] = .string(sameParent)
            fields["closure_scope"] = .object(scope)
            XCTAssertThrowsError(try row(.object(fields)), "Call UUID values must differ")
        }
    }

    func testClosureScopeMalformedNestedGoalRejectsWholePage() throws {
        var child = goal(progress: slot("pending", .null), health: slot("current", .string("At risk"))).objectValue!
        child["closure_scope"] = .null
        var parent = goal(progress: slot("current", .int(73)), health: slot("pending", .null)).objectValue!
        parent["issue_id"] = .string("AGT-12"); parent["goal_id"] = .string("AGT-12")
        parent["issue_url"] = .string("https://linear.app/mjmk/issue/AGT-12")
        parent["closure_obligations"] = .array([.object(child)])
        XCTAssertThrowsError(try row(.object(parent)))
    }

    func testClosureScopeRejectedRefreshKeepsPriorPayloadAvailableAsLastKnown() throws {
        var good = goal(progress: slot("pending", .null), health: slot("current", .string("At risk"))).objectValue!
        good["closure_scope"] = closureScope()
        let previous = page(.object(good))
        var snapshot = previous
        var rows = try GoalOverviewDecoder.rows(snapshot)
        var bad = good; bad["closure_scope"] = .null
        let incoming = page(.object(bad))
        // Same decoder-before-publication order as GoalOverviewScreen; no HTTP or storage substitute.
        do {
            let updated = try GoalOverviewDecoder.rows(incoming)
            snapshot = incoming; rows = updated
            XCTFail("Malformed scope must fail before replacing the last usable snapshot")
        } catch {
            rows = try GoalOverviewDecoder.rows(snapshot, cached: true)
        }
        XCTAssertEqual(snapshot, previous)
        XCTAssertEqual(rows.first?.closureScopeMetadata, closureScope())
        XCTAssertEqual(rows.first?.healthAvailability, .lastKnown)
        XCTAssertEqual(rows.first?.visibleHealth, .atRisk)
    }

    private func closureScope() -> JSONValue {
        .object(["description": .string("Fixture only：承接有限范围，不代整票完成。\n保留原始描述。"),
            "source_url": .string("https://linear.app/mjmk/issue/AGT-34#comment-fa000000-0000-4000-8000-000000000001"),
            "call_id": .string("fa000000-0000-4000-8000-000000000034"),
            "parent_call_id": .string("fa000000-0000-4000-8000-000000000012")])
    }

    private func row(_ goal: JSONValue, cached: Bool = false) throws -> GoalOverviewRow {
        try GoalOverviewDecoder.rows(page(goal), cached: cached).first!
    }

    private func page(_ goal: JSONValue) -> JSONValue {
        .object(["ok": .bool(true), "schema_version": .int(1), "source": .string("goal_observer"),
            "namespace": .string("openai:fixture-only"), "snapshot_revision": .int(11),
            "inventory_observed_at": .string("2026-10-14T04:00:00Z"), "goals": .array([goal])])
    }

    private func metadata(time: String = "2026-10-14T03:00:00Z", version: String = "fixture-new") -> JSONValue {
        .object(["evaluated_at": .string(time), "input_coverage_at": .null, "input_version": .string(version),
            "goal_version": .string("fixture-goal"), "method_version": .string("fixture-method"),
            "sources": .array([.object(["source_type": .string("fixture"), "source_id": .string("fixture-source"),
                "source_revision": .string(version), "memory_revision": .null, "coverage": .null, "covered_at": .null])])])
    }

    private func slot(_ state: String, _ value: JSONValue, observation: JSONValue? = nil) -> JSONValue {
        let reason: JSONValue = state == "current" ? .null : .string(state == "not_applicable" ? "unbounded_goal" : "not_evaluated")
        return .object(["availability": .string(state), "value": value, "unavailability_reason": reason,
            "observation": state == "pending" ? .null : observation ?? metadata()])
    }

    private func goal(progress: JSONValue, health: JSONValue, availability: String = "partial", observation: JSONValue = .null) -> JSONValue {
        .object(["goal_id": .string("AGT-34"), "issue_id": .string("AGT-34"),
            "title": .string("Fixture only：分维可用性与原始完整长标题验证，不是真实评分"),
            "issue_url": .string("https://linear.app/mjmk/issue/AGT-34"), "project": .null,
            "progress": progress.objectValue!["value"]!, "health": health.objectValue!["value"]!,
            "availability": .string(availability), "unavailability_reason": availability == "current" ? .null : .string("not_evaluated"),
            "observation": observation, "dimensions": .object(["Progress": progress, "Health": health]),
            "closure_obligations": .array([]), "workers": .array([])])
    }
}
