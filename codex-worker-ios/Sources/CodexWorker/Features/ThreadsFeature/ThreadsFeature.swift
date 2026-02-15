//
//  ThreadsFeature.swift
//  CodexWorker
//
//  线程列表占位 Feature（里程碑 1）
//

import ComposableArchitecture

@Reducer
struct ThreadsFeature {
    @ObservableState
    struct State: Equatable {
        var items: [Thread] = []
        var isLoading = false
        var selectedThreadId: String?
        var errorMessage: String?

        /// 按更新时间倒序展示线程，保证最近活跃优先
        var sortedItems: [Thread] {
            items.sorted { lhs, rhs in
                (lhs.lastActiveAt ?? .distantPast) > (rhs.lastActiveAt ?? .distantPast)
            }
        }
    }

    enum Action {
        case onAppear
        case refresh
        case loadResponse(Result<ThreadsListResponse, CodexError>)
        case threadTapped(String)
        case selectResponse(Result<Thread, CodexError>)
        case clearError
        case delegate(Delegate)
    }

    enum Delegate {
        case didActivateThread(Thread)
    }

    @Dependency(\.apiClient) var apiClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear, .refresh:
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    await send(
                        .loadResponse(
                            Result {
                                try await apiClient.listThreads()
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .loadResponse(.success(let response)):
                state.isLoading = false
                state.items = response.data
                return .none

            case .loadResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .threadTapped(let threadId):
                state.selectedThreadId = threadId
                state.errorMessage = nil
                return .run { send in
                    await send(
                        .selectResponse(
                            Result {
                                try await apiClient.activateThread(threadId)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .selectResponse(.success(let thread)):
                return .send(.delegate(.didActivateThread(thread)))

            case .selectResponse(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .clearError:
                state.errorMessage = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
