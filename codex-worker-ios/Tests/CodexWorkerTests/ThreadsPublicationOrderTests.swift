import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ThreadsPublicationOrderTests {
    @Test
    func newerSnapshotRejectsLateColdCacheAndItsFailure() {
        var state = ThreadsFeature.State()
        let reducer = ThreadsFeature()
        let coldGeneration = state.catalogGeneration
        let fresh = snapshot(namespace: "fresh", unread: 0)
        _ = reducer.reduce(into: &state, action: .cacheLoaded(fresh))
        let accepted = state
        _ = reducer.reduce(into: &state, action: .initialCacheResponse(generation: coldGeneration, .success(snapshot(namespace: "old", unread: 9))))
        #expect(state == accepted)
        _ = reducer.reduce(into: &state, action: .initialCacheResponse(generation: coldGeneration, .failure(.timeout)))
        #expect(state == accepted)
    }

    @Test
    func newerEmptyCatalogCannotBeRefilledByOldCache() {
        var state = ThreadsFeature.State()
        let reducer = ThreadsFeature()
        let oldGeneration = state.catalogGeneration
        _ = reducer.reduce(into: &state, action: .cacheLoaded(.init(threads: [], metadata: [:], changedThreadIds: [], failures: [:])))
        _ = reducer.reduce(into: &state, action: .initialCacheResponse(generation: oldGeneration, .success(snapshot(namespace: "old", unread: 9))))
        #expect(state.items.isEmpty && state.syncMetadata.isEmpty && state.selectedThreadId == nil)
    }

    @Test
    func acceptedCachePublishesSelectionAtomicallyWithoutASecondListAction() async {
        let cache = snapshot(namespace: "current", unread: 0)
        let store = TestStore(initialState: ThreadsFeature.State()) { ThreadsFeature() }
        await store.send(.initialCacheResponse(generation: 0, .success(cache))) {
            $0.catalogGeneration = 1
            $0.items = cache.threads
            $0.syncMetadata = cache.metadata
            $0.selectedThreadId = "same-id"
        }
        await store.receive({ if case .delegate(.didActivateThread(let thread)) = $0 { return thread.id == cache.threads[0].id }; return false })
        await store.finish()
    }

    @Test
    func parentRejectsLateRootCacheAndOldNamespaceDelegate() async {
        let fresh = snapshot(namespace: "fresh", unread: 0)
        var state = AppFeature.State()
        state.threads.items = fresh.threads
        state.threads.syncMetadata = fresh.metadata
        state.threads.selectedThreadId = "same-id"
        state.threads.catalogGeneration = 2
        state.activeThread = fresh.threads[0]
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.syncCached(generation: 1, snapshot(namespace: "old", unread: 9)))
        await store.send(.threads(.delegate(.didActivateThread(snapshot(namespace: "old", unread: 9).threads[0]))))
        await store.send(.threads(.delegate(.didClearActiveThread)))
        // Exhaustivity also checks that rejected callbacks queue no child action.
        await store.finish()
    }

    private func snapshot(namespace: String, unread: Int) -> MobileSyncResult {
        var thread = CodexWorker.Thread(threadId: "same-id", preview: nil, cwd: nil, createdAt: nil, updatedAt: nil, modelProvider: nil)
        thread.origin = .init(namespace: namespace, hostID: "host")
        return .init(threads: [thread], metadata: ["same-id": .init(lastSyncedAt: nil, unreadMessages: unread, pinned: false)],
                     changedThreadIds: [], failures: [:], selectedThreadId: "same-id")
    }
}
