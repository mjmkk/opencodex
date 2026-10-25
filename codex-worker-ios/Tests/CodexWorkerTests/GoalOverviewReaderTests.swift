import Foundation
import XCTest
@testable import CodexWorker

/// Integration checks use an authorized saved observation, production SQLite,
/// real HTTPS reads, and an actual refused connection. No API/AI response stub.
/// The local verification runner identifies the authorized normal App container;
/// environments without that private input explicitly skip these checks.
@MainActor
final class GoalOverviewReaderTests: XCTestCase {
    @MainActor private final class IdentityStore {
        let defaults: UserDefaults
        let suite = "OverviewReader-" + UUID().uuidString

        init(namespace: String) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set("observed-account", forKey: "current")
            defaults.set(namespace, forKey: "namespace.observed-account")
        }

        func scope() throws -> String {
            guard let value = defaults.string(forKey: "current") else { throw CodexError.notConfigured }
            return value
        }

        func namespace(_ scope: String) -> String? { defaults.string(forKey: "namespace." + scope) }
        func remove() { defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor private final class Delivery {
        var payload: JSONValue?
        let gate = AsyncStream<Void>.makeStream()

        func read() async throws -> JSONValue {
            let value = try await GoalOverviewReaderTests.realRead()
            _ = try GoalOverviewDecoder.rows(value)
            payload = value
            // Delay delivery of a genuine response, without changing its bytes.
            for await _ in gate.stream { break }
            return value
        }

        func release() { gate.continuation.yield(()); gate.continuation.finish() }
    }

    private static func realAppDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AGT12_REAL_APP_DATA_DIRECTORY"] else {
            throw XCTSkip("Requires the authorized normal App container; no generated fixture fallback")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func realRead() async throws -> JSONValue {
        let file = try realAppDirectory().appendingPathComponent("Library/Preferences/chenken.CodexWorkerApp.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
        let values = try XCTUnwrap(plist as? [String: Any])
        let data = try XCTUnwrap(values["codex.worker.configuration"] as? Data)
        _ = try JSONDecoder().decode(WorkerConfiguration.self, from: data)
        // Supply the existing configuration only to this unhosted test process.
        // Never persist credentials or change the normal App's defaults.
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overlay = previous
        overlay["codex.worker.configuration"] = data
        defaults.setVolatileDomain(overlay, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        return try await APIClient.live.goalOverview()
    }

    private func observation() throws -> GoalOverviewCacheEntry {
        let file = try Self.realAppDirectory().appendingPathComponent("Documents/AGT12-Overview-baseline.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Requires the authorized real Overview cache entry; no generated fixture fallback")
        }
        let entry = try JSONDecoder().decode(GoalOverviewCacheEntry.self, from: Data(contentsOf: file))
        _ = try GoalOverviewDecoder.rows(entry.payload)
        return entry
    }

    private func makeIdentity(_ entry: GoalOverviewCacheEntry) throws -> IdentityStore {
        IdentityStore(namespace: try XCTUnwrap(entry.payload.objectValue?["namespace"]?.stringValue))
    }

    private func makeCache() throws -> (MobileSyncCache, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        return (try MobileSyncCache(path: path), path)
    }

    private static func refusedRead() async throws -> JSONValue {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "https://127.0.0.1:1/v1/overview/goals")!)
        // An unexpected listener must not turn the failure check into a pass.
        XCTFail("Expected the isolated closed port to refuse the real request")
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func waitForRealResponse(_ delivery: Delivery, reader: GoalOverviewReader,
                                    pending: Task<Void, Never>, baseline: GoalOverviewCacheEntry) async throws {
        do {
            let deadline = Date().addingTimeInterval(40)
            while delivery.payload == nil && reader.failure == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let payload = try XCTUnwrap(delivery.payload, "A genuine backend response is required")
            let namespace = try XCTUnwrap(payload.objectValue?["namespace"]?.stringValue)
            let revision = try XCTUnwrap(payload.objectValue?["snapshot_revision"]?.intValue)
            let previous = try XCTUnwrap(baseline.payload.objectValue?["snapshot_revision"]?.intValue)
            XCTAssertEqual(namespace, baseline.payload.objectValue?["namespace"]?.stringValue)
            XCTAssertGreaterThanOrEqual(revision, previous)
            guard namespace == baseline.payload.objectValue?["namespace"]?.stringValue,
                  revision >= previous else { throw CodexError.invalidState }
        } catch {
            reader.invalidate()
            pending.cancel()
            delivery.release()
            await pending.value
            throw error
        }
    }

    func testGenuineResponsePersistsAndPublishes() async throws {
        let entry = try observation(), identity = try makeIdentity(entry)
        defer { identity.remove() }
        let (cache, _) = try makeCache()
        var received: JSONValue?
        let reader = GoalOverviewReader(cache: cache, currentScope: identity.scope,
            namespaceForScope: identity.namespace, readRemote: {
                let payload = try await Self.realRead()
                received = payload
                return payload
            })
        await reader.refresh()
        let payload = try XCTUnwrap(received)
        XCTAssertNil(reader.failure)
        XCTAssertTrue(reader.hasSnapshot)
        XCTAssertEqual(reader.rows, try GoalOverviewDecoder.rows(payload))
        XCTAssertEqual(reader.inventoryValidation, try GoalOverviewDecoder.inventoryValidation(payload))
        let retained = try await cache.goalOverview(scope: identity.scope())?.payload
        XCTAssertEqual(retained, payload)
    }

    func testReopenedCacheSurvivesRealConnectionFailure() async throws {
        let entry = try observation(), identity = try makeIdentity(entry)
        defer { identity.remove() }
        let (cache, path) = try makeCache()
        try await cache.saveGoalOverview(entry, scope: identity.scope())
        let reopened = try MobileSyncCache(path: path)
        let reader = GoalOverviewReader(cache: reopened, currentScope: identity.scope,
            namespaceForScope: identity.namespace, readRemote: { try await Self.refusedRead() })
        await reader.refresh()
        XCTAssertEqual(reader.rows, try GoalOverviewDecoder.rows(entry.payload, cached: true))
        XCTAssertEqual(reader.inventoryValidation, try GoalOverviewDecoder.inventoryValidation(entry.payload, cached: true))
        XCTAssertTrue(reader.hasSnapshot)
        XCTAssertFalse(reader.isRefreshing)
        XCTAssertEqual(reader.failure, "读取失败，保留上次观察；判断时间未更新。")
        let retained1 = try await reopened.goalOverview(scope: identity.scope())?.payload
        XCTAssertEqual(retained1, entry.payload)
    }

    func testOtherAccountCannotRestoreSavedObservation() async throws {
        let entry = try observation(), identity = try makeIdentity(entry)
        defer { identity.remove() }
        let (cache, _) = try makeCache()
        try await cache.saveGoalOverview(entry, scope: identity.scope())
        identity.defaults.set("other-account", forKey: "current")
        identity.defaults.set(try XCTUnwrap(entry.payload.objectValue?["namespace"]?.stringValue), forKey: "namespace.other-account")
        let reader = GoalOverviewReader(cache: cache, currentScope: identity.scope,
            namespaceForScope: identity.namespace, readRemote: { try await Self.refusedRead() })
        await reader.refresh()
        XCTAssertTrue(reader.rows.isEmpty)
        XCTAssertFalse(reader.hasSnapshot)
        let absent2 = try await cache.goalOverview(scope: "other-account")
        XCTAssertNil(absent2)
        let retained3 = try await cache.goalOverview(scope: "observed-account")?.payload
        XCTAssertEqual(retained3, entry.payload)
    }

    func testChangedNamespaceCannotPublishStoredObservation() async throws {
        let entry = try observation(), identity = try makeIdentity(entry)
        defer { identity.remove() }
        let (cache, _) = try makeCache()
        try await cache.saveGoalOverview(entry, scope: identity.scope())
        identity.defaults.set("openai:different-source", forKey: "namespace.observed-account")
        let reader = GoalOverviewReader(cache: cache, currentScope: identity.scope,
            namespaceForScope: identity.namespace, readRemote: { try await Self.refusedRead() })
        await reader.refresh()
        XCTAssertTrue(reader.rows.isEmpty)
        XCTAssertFalse(reader.hasSnapshot)
        let retained4 = try await cache.goalOverview(scope: identity.scope())?.payload
        XCTAssertEqual(retained4, entry.payload)
    }

    func testInvalidationRejectsDelayedGenuineResponse() async throws {
        let entry = try observation(), identity = try makeIdentity(entry)
        defer { identity.remove() }
        let (cache, _) = try makeCache()
        try await cache.saveGoalOverview(entry, scope: identity.scope())
        let delivery = Delivery()
        defer { delivery.release() }
        let reader = GoalOverviewReader(cache: cache, currentScope: identity.scope,
            namespaceForScope: identity.namespace, readRemote: delivery.read)
        let pending = Task { await reader.refresh() }
        await Task.yield()
        try await waitForRealResponse(delivery, reader: reader, pending: pending, baseline: entry)
        reader.invalidate()
        delivery.release()
        await pending.value
        XCTAssertEqual(reader.rows, try GoalOverviewDecoder.rows(entry.payload, cached: true))
        XCTAssertFalse(reader.isRefreshing)
        XCTAssertNil(reader.failure)
        let retained5 = try await cache.goalOverview(scope: identity.scope())?.payload
        XCTAssertEqual(retained5, entry.payload)
    }

    func testIdentityRemovalRejectsDelayedGenuineResponse() async throws {
        let entry = try observation(), identity = try makeIdentity(entry)
        defer { identity.remove() }
        let (cache, _) = try makeCache()
        try await cache.saveGoalOverview(entry, scope: identity.scope())
        let delivery = Delivery()
        defer { delivery.release() }
        let reader = GoalOverviewReader(cache: cache, currentScope: identity.scope,
            namespaceForScope: identity.namespace, readRemote: delivery.read)
        let pending = Task { await reader.refresh() }
        await Task.yield()
        try await waitForRealResponse(delivery, reader: reader, pending: pending, baseline: entry)
        identity.defaults.removeObject(forKey: "current")
        reader.identityChanged()
        delivery.release()
        await pending.value
        await Task.yield()
        XCTAssertTrue(reader.rows.isEmpty)
        XCTAssertFalse(reader.hasSnapshot)
        let retained6 = try await cache.goalOverview(scope: "observed-account")?.payload
        XCTAssertEqual(retained6, entry.payload)
    }
}
