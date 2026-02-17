//
//  ThreadsFeature.swift
//  CodexWorker
//
//  线程列表占位 Feature（里程碑 1）
//

import ComposableArchitecture

@Reducer
public struct ThreadsFeature {
    public enum GroupingMode: String, CaseIterable, Equatable, Hashable, Sendable {
        case byCwd
        case byTime

        public var title: String {
            switch self {
            case .byCwd:
                return "按目录"
            case .byTime:
                return "按时间"
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        public struct CwdGroup: Equatable, Identifiable, Sendable {
            public let id: String
            public let title: String
            public let fullPath: String?
            public let threads: [Thread]
        }

        public var items: [Thread] = []
        public var isLoading = false
        public var isCreating = false
        public var selectedThreadId: String?
        public var errorMessage: String?
        public var groupingMode: GroupingMode = .byCwd

        /// 按更新时间倒序展示线程，保证最近活跃优先
        public var sortedItems: [Thread] {
            items.sorted { lhs, rhs in
                (lhs.lastActiveAt ?? .distantPast) > (rhs.lastActiveAt ?? .distantPast)
            }
        }

        /// 按工作目录分组，组内仍按时间倒序
        public var cwdGroups: [CwdGroup] {
            let grouped = Dictionary(grouping: items) { thread -> String in
                let normalized = thread.cwd?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let normalized, !normalized.isEmpty {
                    return normalized
                }
                return "__no_cwd__"
            }

            return grouped
                .map { path, threads in
                    if path == "__no_cwd__" {
                        return CwdGroup(
                            id: path,
                            title: "未设置目录",
                            fullPath: nil,
                            threads: threads.sorted(by: State.compareThreadsByRecency)
                        )
                    }
                    let title = path.split(separator: "/").last.map(String.init) ?? path
                    return CwdGroup(
                        id: path,
                        title: title,
                        fullPath: path,
                        threads: threads.sorted(by: State.compareThreadsByRecency)
                    )
                }
                .sorted { lhs, rhs in
                    switch (lhs.fullPath, rhs.fullPath) {
                    case (nil, nil):
                        return lhs.title < rhs.title
                    case (nil, _):
                        return false
                    case (_, nil):
                        return true
                    case (.some(let l), .some(let r)):
                        return l.localizedStandardCompare(r) == .orderedAscending
                    }
                }
        }

        public init() {}

        private static func compareThreadsByRecency(_ lhs: Thread, _ rhs: Thread) -> Bool {
            (lhs.lastActiveAt ?? .distantPast) > (rhs.lastActiveAt ?? .distantPast)
        }
    }

    public enum Action {
        case onAppear
        case refresh
        case createTapped
        case groupingModeChanged(GroupingMode)
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

            case .groupingModeChanged(let mode):
                state.groupingMode = mode
                return .none

            case .createTapped:
                state.isCreating = true
                state.errorMessage = nil
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    @Dependency(\.executionAccessStore) var executionAccessStore
                    let mode = executionAccessStore.load()
                    let settings = mode.threadRequestSettings
                    await send(
                        .createResponse(
                            Result {
                                try await apiClient.createThread(
                                    .init(
                                        approvalPolicy: settings.approvalPolicy,
                                        sandbox: settings.sandbox
                                    )
                                )
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
