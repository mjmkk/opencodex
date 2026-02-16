//
//  ThreadsFeature.swift
//  CodexWorker
//
//  线程列表占位 Feature（里程碑 1）
//

import ComposableArchitecture

@Reducer
public struct ThreadsFeature {
    @ObservableState
    public struct State: Equatable {
        public var items: [Thread] = []
        public var isLoading = false
        public var isCreating = false
        public var selectedThreadId: String?
        public var errorMessage: String?

        /// 按更新时间倒序展示线程，保证最近活跃优先
        public var sortedItems: [Thread] {
            items.sorted { lhs, rhs in
                (lhs.lastActiveAt ?? .distantPast) > (rhs.lastActiveAt ?? .distantPast)
            }
        }

        public init() {}
    }

    public enum Action {
        case onAppear
        case refresh
        case createTapped
        case loadResponse(Result<ThreadsListResponse, CodexError>)
        case createResponse(Result<Thread, CodexError>)
        case threadTapped(String)
        case clearError
        case delegate(Delegate)
    }

    public enum Delegate {
        case didActivateThread(Thread)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear, .refresh:
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .loadResponse(
                            Result {
                                try await apiClient.listThreads()
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .createTapped:
                state.isCreating = true
                state.errorMessage = nil
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .createResponse(
                            Result {
                                try await apiClient.createThread(.init())
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

            case .createResponse(.success(let thread)):
                state.isCreating = false
                if let index = state.items.firstIndex(where: { $0.threadId == thread.threadId }) {
                    state.items[index] = thread
                } else {
                    state.items.insert(thread, at: 0)
                }
                state.selectedThreadId = thread.threadId
                return .send(.delegate(.didActivateThread(thread)))

            case .createResponse(.failure(let error)):
                state.isCreating = false
                state.errorMessage = error.localizedDescription
                return .none

            case .threadTapped(let threadId):
                guard let thread = state.items.first(where: { $0.threadId == threadId }) else {
                    state.errorMessage = "线程不存在：\(threadId)"
                    return .none
                }
                // 切线程优先本地生效，避免等待网络导致“点击后卡顿”。
                // 后端在发送 turn 时会懒加载线程（startTurn -> ensureThreadLoaded）。
                state.selectedThreadId = threadId
                state.errorMessage = nil
                return .send(.delegate(.didActivateThread(thread)))

            case .clearError:
                state.errorMessage = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
