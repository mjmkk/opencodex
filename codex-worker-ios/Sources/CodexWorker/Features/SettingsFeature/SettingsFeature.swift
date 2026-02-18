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
        public var model = ""
        public var availableModels: [WorkerModel] = []
        public var isLoadingModels = false
        public var modelLoadError: String?
        public var saveSucceeded = false

        public init() {}
    }

    public enum Action {
        case onAppear
        case configurationLoaded(WorkerConfiguration?)
        case modelsLoaded(Result<[WorkerModel], CodexError>)
        case baseURLChanged(String)
        case tokenChanged(String)
        case modelChanged(String)
        case saveTapped
        case saveFinished
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoadingModels = true
                state.modelLoadError = nil
                return .merge(
                    .run { send in
                        @Dependency(\.workerConfigurationStore) var workerConfigurationStore
                        await send(.configurationLoaded(workerConfigurationStore.load()))
                    },
                    .run { send in
                        @Dependency(\.apiClient) var apiClient
                        await send(
                            .modelsLoaded(
                                Result {
                                    try await apiClient.listModels()
                                }.mapError { CodexError.from($0) }
                            )
                        )
                    }
                )

            case .configurationLoaded(let configuration):
                let config = configuration ?? WorkerConfiguration.default
                state.baseURL = config.baseURL
                state.token = config.token ?? ""
                state.model = config.model ?? ""
                state.saveSucceeded = false
                return .none

            case .modelsLoaded(.success(let models)):
                state.isLoadingModels = false
                state.modelLoadError = nil
                state.availableModels = models
                    .reduce(into: [String: WorkerModel]()) { partialResult, item in
                        partialResult[item.id] = item
                    }
                    .values
                    .sorted { lhs, rhs in
                        lhs.listTitle.localizedStandardCompare(rhs.listTitle) == .orderedAscending
                    }
                return .none

            case .modelsLoaded(.failure(let error)):
                state.isLoadingModels = false
                state.modelLoadError = error.localizedDescription
                return .none

            case .baseURLChanged(let value):
                state.baseURL = value
                state.saveSucceeded = false
                return .none

            case .tokenChanged(let value):
                state.token = value
                state.saveSucceeded = false
                return .none

            case .modelChanged(let value):
                state.model = value
                state.saveSucceeded = false
                return .none

            case .saveTapped:
                let configuration = WorkerConfigurationStore.normalized(
                    WorkerConfiguration(
                        baseURL: state.baseURL,
                        token: state.token,
                        model: state.model
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
