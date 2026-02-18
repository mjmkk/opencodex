//
//  ThreadsFeature.swift
//  CodexWorker
//
//  线程列表占位 Feature（里程碑 1）
//

import ComposableArchitecture
import Foundation

@Reducer
public struct ThreadsFeature {
    private enum CancelID {
        case prewarmHistory
    }

    private static let prewarmThreadCount = 3
    private static let prewarmPageLimit = 500
    private static let prewarmMaxPages = 2

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
            public let latestActivityAt: Date
        }

        public var items: [Thread] = []
        public var isLoading = false
        public var isCreating = false
        public var archivingThreadIds: Set<String> = []
        public var hasPrewarmedHistory = false
        public var selectedThreadId: String?
        public var errorMessage: String?
        public var groupingMode: GroupingMode = .byCwd

        /// 按更新时间倒序展示线程，保证最近活跃优先
        public var sortedItems: [Thread] {
            items.sorted(by: State.compareThreadsByRecency)
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
                            threads: threads.sorted(by: State.compareThreadsByRecency),
                            latestActivityAt: threads.map(State.threadRecencyDate).max() ?? .distantPast
                        )
                    }
                    let title = path.split(separator: "/").last.map(String.init) ?? path
                    return CwdGroup(
                        id: path,
                        title: title,
                        fullPath: path,
                        threads: threads.sorted(by: State.compareThreadsByRecency),
                        latestActivityAt: threads.map(State.threadRecencyDate).max() ?? .distantPast
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.latestActivityAt != rhs.latestActivityAt {
                        return lhs.latestActivityAt > rhs.latestActivityAt
                    }
                    switch (lhs.fullPath, rhs.fullPath) {
                    case (.some(let l), .some(let r)):
                        return l.localizedStandardCompare(r) == .orderedAscending
                    case (.some, nil):
                        return true
                    case (nil, .some):
                        return false
                    case (nil, nil):
                        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    }
                }
        }

        public init() {}

        private static func compareThreadsByRecency(_ lhs: Thread, _ rhs: Thread) -> Bool {
            let lhsDate = threadRecencyDate(lhs)
            let rhsDate = threadRecencyDate(rhs)
            if lhsDate == rhsDate {
                return lhs.threadId < rhs.threadId
            }
            return lhsDate > rhsDate
        }

        private static func threadRecencyDate(_ thread: Thread) -> Date {
            thread.lastActiveAt ?? thread.createdDate ?? .distantPast
        }
    }

    public enum Action {
        case onAppear
        case refresh
        case createTapped
        case archiveTapped(String)
        case groupingModeChanged(GroupingMode)
        case loadResponse(Result<ThreadsListResponse, CodexError>)
        case createResponse(Result<Thread, CodexError>)
        case archiveResponse(String, Result<ArchiveThreadResponse, CodexError>)
        case threadTapped(String)
        case clearError
        case delegate(Delegate)
    }

    public enum Delegate {
        case didActivateThread(Thread)
        case didClearActiveThread
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
                                try await apiClient.listThreads(nil)
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
                    @Dependency(\.workerConfigurationStore) var workerConfigurationStore
                    let mode = executionAccessStore.load()
                    let settings = mode.threadRequestSettings
                    let preferredModel = workerConfigurationStore.load()?.model
                    await send(
                        .createResponse(
                            Result {
                                try await apiClient.createThread(
                                    .init(
                                        approvalPolicy: settings.approvalPolicy,
                                        sandbox: settings.sandbox,
                                        model: preferredModel
                                    )
                                )
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .archiveTapped(let threadId):
                guard !state.archivingThreadIds.contains(threadId) else {
                    return .none
                }
                state.archivingThreadIds.insert(threadId)
                state.errorMessage = nil
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    @Dependency(\.threadHistoryStore) var threadHistoryStore
                    do {
                        let response = try await apiClient.archiveThread(threadId)
                        // 归档成功后本地也清理该线程缓存，避免误回放旧历史。
                        try? await threadHistoryStore.resetThread(threadId)
                        await send(.archiveResponse(threadId, .success(response)))
                    } catch {
                        await send(.archiveResponse(threadId, .failure(CodexError.from(error))))
                    }
                }

            case .loadResponse(.success(let response)):
                state.isLoading = false
                state.items = response.data
                let validThreadIds = Set(state.items.map(\.threadId))
                state.archivingThreadIds = state.archivingThreadIds.intersection(validThreadIds)
                if let selectedThreadId = state.selectedThreadId,
                   !state.items.contains(where: { $0.threadId == selectedThreadId })
                {
                    state.selectedThreadId = nil
                }

                let sortedByRecency = state.sortedItems
                let prewarmCandidates = Array(sortedByRecency.prefix(Self.prewarmThreadCount))
                let shouldPrewarm = !state.hasPrewarmedHistory
                if shouldPrewarm {
                    state.hasPrewarmedHistory = true
                }
                let shouldAutoActivate = state.selectedThreadId == nil
                let autoActivateTarget = shouldAutoActivate ? sortedByRecency.first : nil
                if let autoActivateTarget {
                    state.selectedThreadId = autoActivateTarget.threadId
                }

                return .merge(
                    shouldPrewarm
                        ? .run { _ in
                            @Dependency(\.apiClient) var apiClient
                            @Dependency(\.threadHistoryStore) var threadHistoryStore

                            for thread in prewarmCandidates {
                                if Task.isCancelled {
                                    return
                                }
                                do {
                                    try await Self.prewarmThreadHistory(
                                        threadId: thread.threadId,
                                        apiClient: apiClient,
                                        threadHistoryStore: threadHistoryStore
                                    )
                                } catch {
                                    // 预热失败不影响主流程，避免干扰线程列表可用性。
                                }
                            }
                        }
                        .cancellable(id: CancelID.prewarmHistory, cancelInFlight: true)
                        : .none,
                    autoActivateTarget.map { .send(.delegate(.didActivateThread($0))) } ?? .none
                )

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

            case .archiveResponse(let threadId, .success):
                state.archivingThreadIds.remove(threadId)
                let wasSelected = state.selectedThreadId == threadId
                state.items.removeAll { $0.threadId == threadId }
                if !wasSelected {
                    return .none
                }
                let nextThread = state.sortedItems.first
                state.selectedThreadId = nextThread?.threadId
                if let nextThread {
                    return .send(.delegate(.didActivateThread(nextThread)))
                }
                return .send(.delegate(.didClearActiveThread))

            case .archiveResponse(let threadId, .failure(let error)):
                state.archivingThreadIds.remove(threadId)
                state.errorMessage = error.localizedDescription
                return .none

            case .threadTapped(let threadId):
                guard !state.archivingThreadIds.contains(threadId) else {
                    return .none
                }
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

    private static func prewarmThreadHistory(
        threadId: String,
        apiClient: APIClient,
        threadHistoryStore: ThreadHistoryStore
    ) async throws {
        var cursor = try await threadHistoryStore.loadCursor(threadId)
        var hasResetOnce = false
        var fetchedPages = 0

        while fetchedPages < prewarmMaxPages {
            do {
                let page = try await apiClient.listThreadEvents(threadId, cursor, prewarmPageLimit)
                if page.hasMore, page.nextCursor <= cursor {
                    return
                }
                try await threadHistoryStore.mergeRemotePage(threadId, cursor, page)
                cursor = page.nextCursor
                fetchedPages += 1
                if !page.hasMore || page.data.isEmpty {
                    return
                }
            } catch let error as CodexError where error == .cursorExpired {
                if hasResetOnce {
                    return
                }
                hasResetOnce = true
                try await threadHistoryStore.resetThread(threadId)
                cursor = -1
            }
        }
    }
}
