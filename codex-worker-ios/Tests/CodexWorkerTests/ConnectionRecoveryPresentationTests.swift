import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ConnectionRecoveryPresentationTests {
    @Test
    func systemATSFailureKeepsItsReasonAndUsesConfigurationRecovery() {
        let original = URLError(.appTransportSecurityRequiresSecureConnection)
        let error = CodexError.from(original)
        guard case .secureConnectionRequired(let reason) = error else {
            Issue.record("ATS must remain a typed configuration failure")
            return
        }
        #expect(reason == original.localizedDescription)
        #expect(error.localizedDescription.contains(reason))
        #expect(!error.isTransient)
        guard case .reconfigure = error.recoveryStrategy else {
            Issue.record("Retrying must not be offered as the primary ATS recovery")
            return
        }
    }

    @Test
    func temporaryFailureRetainsRetryAsTheRecovery() {
        var state = ThreadsFeature.State()
        let error = CodexError.from(URLError(.timedOut))
        _ = ThreadsFeature().reduce(into: &state, action: .loadResponse(.failure(error)))
        #expect(error == .timeout && error.isTransient)
        #expect(state.failure == .timeout)
        #expect(!state.needsConnectionSettings)
    }

    @Test
    func successfulReadClearsAnOldConfigurationFailure() {
        var state = ThreadsFeature.State()
        let reducer = ThreadsFeature()
        _ = reducer.reduce(into: &state, action: .loadResponse(.failure(.unauthorized)))
        #expect(state.needsConnectionSettings)
        _ = reducer.reduce(into: &state, action: .loadResponse(.success(.init(data: [], nextCursor: nil))))
        #expect(state.failure == nil && state.errorMessage == nil)
        #expect(!state.needsConnectionSettings)
    }

    @Test
    func parentSyncFailurePublishesItsTypedRecoveryWithItsMessage() async {
        var initial = AppFeature.State()
        initial.threads.isSyncing = true
        let requestID = UUID()
        initial.syncRequestID = requestID
        let store = TestStore(initialState: initial) { AppFeature() }
        let error = CodexError.secureConnectionRequired("system reason")
        await store.send(.syncResponse(requestID: requestID, .failure(error))) {
            $0.syncRequestID = nil
            $0.threads.isSyncing = false
            $0.threads.failure = error
            $0.threads.errorMessage = "同步未完成，保留本地内容：" + error.localizedDescription
        }
        #expect(store.state.syncRequestID == nil && !store.state.threads.isSyncing)
        #expect(store.state.threads.failure == error)
        #expect(store.state.threads.errorMessage == "同步未完成，保留本地内容：" + error.localizedDescription)
        #expect(store.state.threads.needsConnectionSettings)
        await store.finish()
    }
}
