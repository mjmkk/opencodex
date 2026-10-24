import ComposableArchitecture
import Testing
@testable import CodexWorker

@MainActor
struct ConnectionCheckActivityTests {
    @Test
    func checkingRetainsTheLastFailureForReading() {
        var state = AppFeature.State()
        state.workerReachability = .unreachable("previous failure")
        state.connectionState = .failed("previous failure")
        _ = AppFeature().reduce(into: &state, action: .healthCheckNow)
        #expect(state.isCheckingConnection)
        #expect(state.workerReachability == .unreachable("previous failure"))
        #expect(state.connectionState == .failed("previous failure"))
    }

    @Test
    func overlappingChecksRemainBusyUntilTheLastResponse() {
        var state = AppFeature.State()
        let reducer = AppFeature()
        _ = reducer.reduce(into: &state, action: .healthCheckNow)
        _ = reducer.reduce(into: &state, action: .healthCheckNow)
        #expect(state.pendingHealthChecks == 2)
        _ = reducer.reduce(into: &state, action: .healthCheckResponse(.failure(.timeout)))
        #expect(state.pendingHealthChecks == 1 && state.isCheckingConnection)
        _ = reducer.reduce(into: &state, action: .healthCheckResponse(.failure(.timeout)))
        #expect(state.pendingHealthChecks == 0 && !state.isCheckingConnection)
    }

    @Test
    func reachableCheckTracksRequestActivitySeparatelyFromLastResult() {
        var state = AppFeature.State()
        state.workerReachability = .reachable
        state.connectionState = .connected
        let reducer = AppFeature()
        _ = reducer.reduce(into: &state, action: .healthCheckNow)
        #expect(state.isCheckingConnection && state.connectionState == .connected)
        _ = reducer.reduce(into: &state, action: .healthCheckResponse(.failure(.timeout)))
        #expect(!state.isCheckingConnection)
        #expect(state.connectionState == .failed(CodexError.timeout.localizedDescription))
    }
}
