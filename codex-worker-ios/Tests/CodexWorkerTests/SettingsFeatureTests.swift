import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct SettingsFeatureTests {
    @Test
    func onAppearLoadsPersistedConfiguration() async {
        let persisted = WorkerConfiguration(
            baseURL: "http://192.168.31.9:8787",
            token: "token-123",
            model: "openai/gpt-5"
        )

        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.workerConfigurationStore.load = { persisted }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.configurationLoaded) {
            $0.baseURL = "http://192.168.31.9:8787"
            $0.token = "token-123"
            $0.model = "openai/gpt-5"
            $0.saveSucceeded = false
        }
    }

    @Test
    func saveTappedPersistsNormalizedConfiguration() async {
        let saved = LockedConfigBox()
        var initialState = SettingsFeature.State()
        initialState.baseURL = "  http://127.0.0.1:8787/  "
        initialState.token = "  abc  "
        initialState.model = "  openai/gpt-5-mini  "

        let store = TestStore(initialState: initialState) {
            SettingsFeature()
        } withDependencies: {
            $0.workerConfigurationStore.save = { configuration in
                saved.set(configuration)
            }
        }

        await store.send(.saveTapped)
        await store.receive(\.saveFinished) {
            $0.saveSucceeded = true
        }

        let persisted = saved.get()
        #expect(persisted?.baseURL == "http://127.0.0.1:8787")
        #expect(persisted?.token == "abc")
        #expect(persisted?.model == "openai/gpt-5-mini")
    }
}

private final class LockedConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WorkerConfiguration?

    func set(_ newValue: WorkerConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> WorkerConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
