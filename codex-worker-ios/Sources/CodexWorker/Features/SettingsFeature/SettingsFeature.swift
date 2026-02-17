//
//  SettingsFeature.swift
//  CodexWorker
//
//  设置占位 Feature（里程碑 1）
//

import ComposableArchitecture

@Reducer
public struct SettingsFeature {
    @ObservableState
    public struct State: Equatable {
        public var baseURL = WorkerConfiguration.default.baseURL
        public var token = ""
        public var saveSucceeded = false

        public init() {}
    }

    public enum Action {
        case onAppear
        case configurationLoaded(WorkerConfiguration?)
        case baseURLChanged(String)
        case tokenChanged(String)
        case saveTapped
        case saveFinished
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    @Dependency(\.workerConfigurationStore) var workerConfigurationStore
                    await send(.configurationLoaded(workerConfigurationStore.load()))
                }

            case .configurationLoaded(let configuration):
                let config = configuration ?? WorkerConfiguration.default
                state.baseURL = config.baseURL
                state.token = config.token ?? ""
                state.saveSucceeded = false
                return .none

            case .baseURLChanged(let value):
                state.baseURL = value
                state.saveSucceeded = false
                return .none

            case .tokenChanged(let value):
                state.token = value
                state.saveSucceeded = false
                return .none

            case .saveTapped:
                let configuration = WorkerConfigurationStore.normalized(
                    WorkerConfiguration(
                        baseURL: state.baseURL,
                        token: state.token
                    )
                )
                state.saveSucceeded = false
                return .run { send in
                    @Dependency(\.workerConfigurationStore) var workerConfigurationStore
                    workerConfigurationStore.save(configuration)
                    await send(.saveFinished)
                }

            case .saveFinished:
                state.saveSucceeded = true
                return .none
            }
        }
    }
}
