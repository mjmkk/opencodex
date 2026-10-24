import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ThreadsFeatureTests {
    @Test
    func cwdGroupsSortByGroupRecencyThenPath() {
        var state = ThreadsFeature.State()
        state.items = [
            Thread(
                threadId: "t1",
                preview: "A-old",
                cwd: "/repo/A",
                createdAt: "2026-02-18T08:00:00.000Z",
                updatedAt: "2026-02-18T08:00:00.000Z",
                modelProvider: "openai"
            ),
            Thread(
                threadId: "t2",
                preview: "B-new",
                cwd: "/repo/B",
                createdAt: "2026-02-18T11:00:00.000Z",
                updatedAt: "2026-02-18T11:00:00.000Z",
                modelProvider: "openai"
            ),
            Thread(
                threadId: "t3",
                preview: "No-cwd-mid",
                cwd: nil,
                createdAt: "2026-02-18T10:00:00.000Z",
                updatedAt: "2026-02-18T10:00:00.000Z",
                modelProvider: "openai"
            ),
        ]

        let groups = state.cwdGroups
        #expect(groups.count == 3)
        #expect(groups[0].id == "/repo/B")
        #expect(groups[1].id == "__no_cwd__")
        #expect(groups[2].id == "/repo/A")
    }

    @Test
    func cacheReplacesIdentityAndMetadataInOneStateUpdate() {
        var old = thread("shared", namespace: "old-scope")
        old.name = "Previous identity"
        let current = thread("shared", namespace: "current-scope")
        var state = ThreadsFeature.State()
        state.items = [old]
        state.syncMetadata = ["shared": .init(lastSyncedAt: .distantPast, unreadMessages: 9, pinned: true)]
        let metadata = ThreadSyncMetadata(lastSyncedAt: .distantFuture, unreadMessages: 0, pinned: false)
        let cache = MobileSyncResult(threads: [current], metadata: ["shared": metadata], changedThreadIds: [], failures: [:])
        _ = ThreadsFeature().reduce(into: &state, action: .cacheLoaded(cache))
        #expect(state.items == [current])
        #expect(state.items.first?.id != old.id)
        #expect(state.syncMetadata == ["shared": metadata])
    }

    @Test
    func cacheRestoresSelectionAndRetainsExistingValidSelection() {
        let first = thread("first", namespace: "scope")
        let second = thread("second", namespace: "scope")
        let cache = MobileSyncResult(threads: [first, second], metadata: [:], changedThreadIds: [], failures: [:], selectedThreadId: "second")
        var state = ThreadsFeature.State()
        _ = ThreadsFeature().reduce(into: &state, action: .cacheLoaded(cache))
        #expect(state.selectedThreadId == "second")
        _ = ThreadsFeature().reduce(into: &state, action: .loadResponse(.success(.init(data: cache.threads, nextCursor: nil))))
        #expect(state.selectedThreadId == "second")
        state.selectedThreadId = "first"
        _ = ThreadsFeature().reduce(into: &state, action: .cacheLoaded(cache))
        _ = ThreadsFeature().reduce(into: &state, action: .loadResponse(.success(.init(data: cache.threads, nextCursor: nil))))
        #expect(state.selectedThreadId == "first")
    }

    @Test
    func removedSelectionFallsBackAfterCacheAndMetadataDoesNotLinger() {
        let current = thread("current", namespace: "scope")
        var state = ThreadsFeature.State()
        state.selectedThreadId = "removed"
        state.syncMetadata = ["removed": .init(lastSyncedAt: .distantPast, unreadMessages: 1, pinned: true)]
        let cache = MobileSyncResult(threads: [current], metadata: [:], changedThreadIds: [], failures: [:])
        _ = ThreadsFeature().reduce(into: &state, action: .cacheLoaded(cache))
        #expect(state.syncMetadata.isEmpty)
        _ = ThreadsFeature().reduce(into: &state, action: .loadResponse(.success(.init(data: [current], nextCursor: nil))))
        #expect(state.selectedThreadId == "current")
    }

    private func thread(_ id: String, namespace: String) -> Thread {
        var value = Thread(threadId: id, preview: nil, cwd: nil, createdAt: nil, updatedAt: nil, modelProvider: nil)
        value.origin = .init(namespace: namespace, hostID: nil)
        return value
    }

}
