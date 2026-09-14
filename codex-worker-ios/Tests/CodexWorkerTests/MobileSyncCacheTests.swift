import Foundation
import Testing
@testable import CodexWorker

struct MobileSyncCacheTests {
    private func event(_ cursor: Int, text: String = "fixture") -> EventEnvelope {
        .init(type: "item.completed", ts: "2026-09-15T00:00:00Z", jobId: "job", seq: cursor,
              payload: ["text": .string(text)], threadCursor: cursor)
    }
    private func page(_ cursors: [Int], generation: String = "one", more: Bool = false) -> ThreadEventsResponse {
        .init(data: cursors.map { event($0) }, nextCursor: cursors.last ?? -1, hasMore: more, generation: generation)
    }
    private var thread: CodexWorker.Thread {
        .init(threadId: "original", preview: "Fixture", cwd: "/repo", createdAt: nil, updatedAt: nil, modelProvider: nil)
    }

    @Test func rebuildStagesUntilCompleteAndPreservesOfflineContent() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        try await cache.saveThreads([thread], scope: "account")
        try await cache.merge(page([0, 1]), after: .init(), threadId: "original", scope: "account")
        try await cache.markRead("original", scope: "account")
        try await cache.merge(page([0], generation: "two", more: true), after: .init(replacingGeneration: "one"), threadId: "original", scope: "account")
        #expect(try await cache.events("original", scope: "account").count == 2)
        #expect(try await cache.metadata(scope: "account")["original"]?.generation == "one")
        #expect(try await cache.metadata(scope: "account")["original"]?.isRebuilding == true)
        try await cache.merge(page([1, 2], generation: "two"), after: .init(cursor: 0, generation: "two"), threadId: "original", scope: "account")
        #expect(try await cache.events("original", scope: "account").count == 3)
        #expect(try await cache.metadata(scope: "account")["original"]?.generation == "two")
        #expect(try await cache.metadata(scope: "account")["original"]?.unreadEvents == 3)
    }

    @Test func duplicatePagesNeverRegressAndConflictingPayloadsAreRejected() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let first = page([0], more: true)
        try await cache.merge(first, after: .init(), threadId: "original", scope: "a")
        try await cache.merge(page([1]), after: .init(cursor: 0, generation: "one"), threadId: "original", scope: "a")
        try await cache.merge(first, after: .init(), threadId: "original", scope: "a")
        #expect(try await cache.checkpoint("original", scope: "a").cursor == 1)
        do {
            let conflicting = ThreadEventsResponse(data: [event(0, text: "different")], nextCursor: 0, hasMore: true, generation: "one")
            try await cache.merge(conflicting, after: .init(), threadId: "original", scope: "a")
            Issue.record("A conflicting cursor must not overwrite cached content")
        } catch { #expect(error as? CodexError == .invalidState) }
        #expect(try await cache.events("original", scope: "a").first?.payloadString("text") == "fixture")
    }

    @Test func gapDoesNotCommitAndProvisionalStreamIsNotRepeated() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        try await cache.appendProvisional([event(0), event(0)], threadId: "original", scope: "a")
        #expect(try await cache.events("original", scope: "a").count == 1)
        do {
            try await cache.merge(page([2]), after: .init(), threadId: "original", scope: "a")
            Issue.record("Missing events must not advance the checkpoint")
        } catch { #expect(error as? CodexError == .invalidState) }
        #expect(try await cache.checkpoint("original", scope: "a").cursor == -1)
        try await cache.merge(page([0]), after: .init(), threadId: "original", scope: "a")
        try await cache.appendProvisional([event(0)], threadId: "original", scope: "a")
        #expect(try await cache.events("original", scope: "a").count == 1)
        #expect(try await cache.events("original", scope: "other-account").isEmpty)
    }

    @Test func cacheAndExplicitPinSurviveColdReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let first = try MobileSyncCache(path: path)
        try await first.saveThreads([thread], scope: "a")
        #expect(try await first.metadata(scope: "a")["original"]?.pinned == false)
        try await first.setPinned(true, threadId: "original", scope: "a")
        try await first.merge(page([0]), after: .init(), threadId: "original", scope: "a")
        let reopened = try MobileSyncCache(path: path)
        #expect(try await reopened.threads(scope: "a").count == 1)
        #expect(try await reopened.events("original", scope: "a").count == 1)
        #expect(try await reopened.metadata(scope: "a")["original"]?.pinned == true)
        try await reopened.setPinned(false, threadId: "original", scope: "a")
        #expect(try await first.metadata(scope: "a")["original"]?.pinned == false)
    }
}
