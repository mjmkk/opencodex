import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct AppFeatureConnectionTests {
    @Test
    func disappearingReleasesSyncBusyWithoutDiscardingReadableState() {
        var state = AppFeature.State()
        state.syncRequestID = UUID()
        state.threads.isSyncing = true
        state.threads.failure = .timeout
        state.threads.errorMessage = "已保留上次列表"

        _ = AppFeature().reduce(into: &state, action: .onDisappear)

        #expect(!state.threads.isSyncing)
        #expect(state.syncRequestID == nil)
        #expect(state.threads.failure == .timeout)
        #expect(state.threads.errorMessage == "已保留上次列表")
    }

    @Test
    func cancellationOnlyReleasesItsOwnReadAndPreservesReadableState() {
        let requestID = UUID()
        var state = AppFeature.State()
        state.syncRequestID = requestID
        state.threads.isSyncing = true
        state.threads.failure = .timeout
        state.threads.errorMessage = "已保留上次列表"
        var expected = state
        expected.syncRequestID = nil
        expected.threads.isSyncing = false
        let reducer = AppFeature()

        _ = reducer.reduce(into: &state, action: .syncCancelled(requestID: requestID))
        #expect(state == expected)
        _ = reducer.reduce(into: &state, action: .syncCancelled(requestID: requestID))
        #expect(state == expected)
    }

    @Test
    func lateResultsCannotFinishTheReadStartedAfterCancellation() throws {
        let oldID = UUID()
        var state = AppFeature.State()
        state.syncRequestID = oldID
        state.threads.isSyncing = true
        let reducer = AppFeature()
        _ = reducer.reduce(into: &state, action: .onDisappear)
        // Reduce only: the returned network effect is never executed by this test.
        _ = reducer.reduce(into: &state, action: .syncNow)
        let currentID = try #require(state.syncRequestID)
        #expect(currentID != oldID && state.threads.isSyncing)
        let reading = state
        let result = MobileSyncResult(threads: [], metadata: [:], changedThreadIds: [], failures: [:])

        for action: AppFeature.Action in [
            .syncCancelled(requestID: oldID),
            .syncResponse(requestID: oldID, .failure(.timeout)),
            .syncResponse(requestID: oldID, .success(result))
        ] {
            _ = reducer.reduce(into: &state, action: action)
            #expect(state == reading)
        }

        _ = reducer.reduce(into: &state, action: .syncResponse(requestID: currentID, .success(result)))
        #expect(state.syncRequestID == nil && !state.threads.isSyncing)
        #expect(state.threads.failure == nil && state.threads.errorMessage == nil)
        let finished = state
        _ = reducer.reduce(into: &state, action: .syncResponse(requestID: currentID, .failure(.timeout)))
        #expect(state == finished)
    }

    @Test
    func backgroundReleasesSyncOwnershipBeforeCancellation() {
        var state = AppFeature.State()
        state.syncRequestID = UUID()
        state.threads.isSyncing = true
        var expected = state
        expected.syncRequestID = nil
        expected.threads.isSyncing = false

        _ = AppFeature().reduce(into: &state, action: .lifecycleChanged(.background))

        #expect(state == expected)
    }

    @Test
    func reportsReachabilityWithoutRetiredEventStream() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(
            .healthCheckResponse(
                .success(HealthCheckResponse(status: "ok", authEnabled: false))
            )
        ) {
            $0.workerReachability = .reachable
            $0.connectionState = .connected
        }
        #expect(store.state.workerReachability == .reachable)
        #expect(store.state.connectionState == .connected)

        await store.send(.healthCheckResponse(.failure(.connectionFailed("server down")))) {
            $0.workerReachability = .unreachable("连接失败: server down")
            $0.connectionState = .failed("连接失败: server down")
        }
        #expect(store.state.workerReachability == .unreachable("连接失败: server down"))
        #expect(store.state.connectionState == .failed("连接失败: server down"))
    }
}
