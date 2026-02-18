//
//  SettingsFeature.swift
//  CodexWorker
//
//  设置占位 Feature（里程碑 1）
//

import ComposableArchitecture
import Foundation

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
        public var archivedThreads: [Thread] = []
        public var isLoadingArchivedThreads = false
        public var archivedThreadsLoadError: String?
        public var restoringThreadIds: Set<String> = []
        public var saveSucceeded = false

        public init() {}

        static func compareThreadsByRecency(_ lhs: Thread, _ rhs: Thread) -> Bool {
            let lhsDate = threadRecencyDate(lhs)
            let rhsDate = threadRecencyDate(rhs)
            if lhsDate == rhsDate {
                return lhs.threadId < rhs.threadId
            }
            return lhsDate > rhsDate
        }

        static func threadRecencyDate(_ thread: Thread) -> Date {
            thread.lastActiveAt ?? thread.createdDate ?? .distantPast
        }
    }

    public enum Action {
        case onAppear
        case configurationLoaded(WorkerConfiguration?)
        case modelsLoaded(Result<[WorkerModel], CodexError>)
        case archivedThreadsLoaded(Result<[Thread], CodexError>)
        case baseURLChanged(String)
        case tokenChanged(String)
        case modelChanged(String)
        case restoreArchivedTapped(String)
        case restoreArchivedResponse(String, Result<ArchiveThreadResponse, CodexError>)
        case saveTapped
        case saveFinished
        case delegate(Delegate)
    }

    public enum Delegate {
        case didRestoreArchivedThread(String)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoadingModels = true
                state.isLoadingArchivedThreads = true
                state.modelLoadError = nil
                state.archivedThreadsLoadError = nil
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
                    },
                    .run { send in
                        @Dependency(\.apiClient) var apiClient
                        await send(
                            .archivedThreadsLoaded(
                                Result {
                                    try await apiClient.listThreads(true).data
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
                if !state.model.isEmpty,
                   !state.availableModels.contains(where: { $0.id == state.model })
                {
                    state.model = ""
                }
                return .none

            case .modelsLoaded(.failure(let error)):
                state.isLoadingModels = false
                state.modelLoadError = error.localizedDescription
                return .none

            case .archivedThreadsLoaded(.success(let threads)):
                state.isLoadingArchivedThreads = false
                state.archivedThreadsLoadError = nil
                state.archivedThreads = threads.sorted(by: State.compareThreadsByRecency)
                state.restoringThreadIds = state.restoringThreadIds
                    .intersection(Set(threads.map(\.threadId)))
                return .none

            case .archivedThreadsLoaded(.failure(let error)):
                state.isLoadingArchivedThreads = false
                state.archivedThreadsLoadError = error.localizedDescription
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

            case .restoreArchivedTapped(let threadId):
                guard !state.restoringThreadIds.contains(threadId) else {
                    return .none
                }
                state.restoringThreadIds.insert(threadId)
                state.archivedThreadsLoadError = nil
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .restoreArchivedResponse(
                            threadId,
                            Result {
                                try await apiClient.unarchiveThread(threadId)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .restoreArchivedResponse(let threadId, .success):
                state.restoringThreadIds.remove(threadId)
                state.archivedThreads.removeAll { $0.threadId == threadId }
                return .send(.delegate(.didRestoreArchivedThread(threadId)))

            case .restoreArchivedResponse(let threadId, .failure(let error)):
                state.restoringThreadIds.remove(threadId)
                state.archivedThreadsLoadError = error.localizedDescription
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

            case .delegate:
                return .none
            }
        }
    }
}
