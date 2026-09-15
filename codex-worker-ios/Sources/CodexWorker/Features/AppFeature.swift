//
//  AppFeature.swift
//  CodexWorker
//
//  根 Feature：承载全局状态与路由
//

import ComposableArchitecture
import Foundation

@Reducer
public struct AppFeature {
    private enum CancelID {
        case healthMonitor
        case syncLoop
        case syncRequest
    }

    public enum WorkerReachability: Equatable, Sendable {
        case unknown
        case checking
        case reachable
        case unreachable(String)
    }

    public enum LifecycleState: Equatable, Sendable {
        case active
        case inactive
        case background
    }

    @ObservableState
    public struct State: Equatable {
        public var connectionState: ConnectionState = .disconnected
        public var workerReachability: WorkerReachability = .unknown
        public var streamConnectionState: ChatFeature.StreamConnectionState = .idle
        public var executionAccessMode: ExecutionAccessMode = .defaultPermissions
        public var threads = ThreadsFeature.State()
        public var chat = ChatFeature.State()
        public var terminal = TerminalFeature.State()
        public var fileBrowser = FileBrowserFeature.State()
        public var approval = ApprovalFeature.State()
        public var mobileInbox = MobileInboxFeature.State()
        public var settings = SettingsFeature.State()
        public var activeThread: Thread?
        public var isDrawerPresented = true
        public var isFileBrowserPresented = false
        public var pendingNotificationThread: String?

        public init() {}
    }

    public enum Action {
        case onAppear
        case onDisappear
        case threads(ThreadsFeature.Action)
        case chat(ChatFeature.Action)
        case terminal(TerminalFeature.Action)
        case fileBrowser(FileBrowserFeature.Action)
        case approval(ApprovalFeature.Action)
        case mobileInbox(MobileInboxFeature.Action)
        case settings(SettingsFeature.Action)
        case lifecycleChanged(LifecycleState)
        case setDrawerPresented(Bool)
        case setFileBrowserPresented(Bool)
        case openFileReference(String)
        case setExecutionAccessMode(ExecutionAccessMode)
        case healthCheckNow
        case healthCheckResponse(Result<HealthCheckResponse, CodexError>)
        case syncNow
        case syncResponse(Result<MobileSyncResult, CodexError>)
        case syncCached(MobileSyncResult)
        case openNotificationThread(String)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.threads, action: \.threads) { ThreadsFeature() }
        Scope(state: \.chat, action: \.chat) { ChatFeature() }
        Scope(state: \.terminal, action: \.terminal) { TerminalFeature() }
        Scope(state: \.fileBrowser, action: \.fileBrowser) { FileBrowserFeature() }
        Scope(state: \.approval, action: \.approval) { ApprovalFeature() }
        Scope(state: \.mobileInbox, action: \.mobileInbox) { MobileInboxFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }

        Reduce { state, action in
            switch action {
            case .onAppear:
                if state.activeThread == nil {
                    state.isDrawerPresented = true
                }
                return .merge(
                    syncLoop(),
                    .run { send in
                        @Dependency(\.workerConfigurationStore) var workerConfigurationStore
                        @Dependency(\.executionAccessStore) var executionAccessStore
                        if workerConfigurationStore.load() == nil {
                            workerConfigurationStore.save(.default)
                        }
                        await send(.setExecutionAccessMode(executionAccessStore.load()))
                        await send(.healthCheckNow)
                    },
                    .run { send in
                        @Dependency(\.continuousClock) var clock
                        while !Task.isCancelled {
                            try await clock.sleep(for: .seconds(15))
                            await send(.healthCheckNow)
                        }
                    }
                    .cancellable(id: CancelID.healthMonitor, cancelInFlight: true)
                )

            case .onDisappear:
                return .merge(.cancel(id: CancelID.healthMonitor), .cancel(id: CancelID.syncLoop), .cancel(id: CancelID.syncRequest))

            case .lifecycleChanged(let lifecycle):
                switch lifecycle {
                case .active:
                    return .merge(
                        syncLoop(),
                        .send(.healthCheckNow),
                        .send(.chat(.appDidBecomeActive))
                    )
                case .background:
                    state.threads.isSyncing = false
                    return .merge(.send(.chat(.appDidEnterBackground)),
                        .cancel(id: CancelID.syncLoop), .cancel(id: CancelID.syncRequest))
                case .inactive:
                    return .none
                }

            case .healthCheckNow:
                if shouldEnterCheckingState(state.workerReachability) {
                    state.workerReachability = .checking
                    recalculateConnectionState(state: &state)
                }
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .healthCheckResponse(
                            Result {
                                try await apiClient.healthCheck()
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }


            case .syncNow:
                guard !state.threads.isSyncing else { return .none }
                state.threads.isSyncing = true
                let preferred = state.activeThread.map { [$0.threadId] } ?? []
                return .run { send in
                    @Dependency(\.threadSyncClient) var sync
                    do { await send(.syncResponse(.success(try await sync.sync(preferred, false)))) }
                    catch is CancellationError { }
                    catch { await send(.syncResponse(.failure(CodexError.from(error)))) }
                }.cancellable(id: CancelID.syncRequest, cancelInFlight: true)

            case .syncResponse(.failure(let error)):
                state.threads.isSyncing = false
                state.threads.errorMessage = "同步未完成，保留本地内容：" + error.localizedDescription
                return .none

            case .syncResponse(.success(let result)):
                state.threads.isSyncing = false
                state.threads.errorMessage = result.failures.isEmpty ? nil : "部分任务尚未同步，已保留本地内容。"
                if let id = state.activeThread?.threadId {
                    state.chat.lastSyncedAt = result.metadata[id]?.lastSyncedAt
                    if let fresh = result.threads.first(where: { $0.threadId == id }) {
                        state.activeThread = fresh; state.chat.activeThread = fresh
                    }
                }
                let target = state.pendingNotificationThread
                if target != nil && result.threads.contains(where: { $0.threadId == target }) { state.pendingNotificationThread = nil }
                return .merge(.send(.threads(.cacheLoaded(result))),
                    refreshCachedChat(state: state, changed: result.changedThreadIds),
                    .run { send in
                        await MobileLifecycle.updatePinned(result)
                        if let target, result.threads.contains(where: { $0.threadId == target }) {
                            await send(.threads(.threadTapped(target)))
                        }
                    })

            case .syncCached(let result):
                return .send(.threads(.cacheLoaded(result)))

            case .openNotificationThread(let id):
                if state.threads.items.contains(where: { $0.threadId == id }) {
                    state.pendingNotificationThread = nil
                    return .send(.threads(.threadTapped(id)))
                }
                state.pendingNotificationThread = id
                return .send(.syncNow)

            case .healthCheckResponse(.success):
                state.workerReachability = .reachable
                recalculateConnectionState(state: &state)
                return .none

            case .healthCheckResponse(.failure(let error)):
                state.workerReachability = .unreachable(error.localizedDescription)
                recalculateConnectionState(state: &state)
                return .none

            case .setDrawerPresented(let presented):
                state.isDrawerPresented = presented
                return .none

            case .setFileBrowserPresented(let presented):
                state.isFileBrowserPresented = presented
                return .none

            case .openFileReference(let reference):
                guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .none
                }
                state.isFileBrowserPresented = true
                return .send(.fileBrowser(.openFromReference(reference)))

            case .setExecutionAccessMode(let mode):
                state.executionAccessMode = mode
                return .run { _ in
                    @Dependency(\.executionAccessStore) var executionAccessStore
                    executionAccessStore.save(mode)
                }

            case .threads(.delegate(.didActivateThread(let thread))):
                state.activeThread = thread
                state.isDrawerPresented = false
                return .merge(
                    .run { _ in
                        @Dependency(\.threadSyncClient) var sync
                        try? await sync.markRead(thread.threadId)
                    },
                    // 切线程时先清理旧线程审批弹层，避免跨线程串窗。
                    .send(.approval(.dismiss)),
                    .send(.chat(.setApprovalLocked(false))),
                    .send(.chat(.setActiveThread(thread))),
                    .send(.terminal(.setActiveThread(thread))),
                    .send(.fileBrowser(.setActiveThread(thread)))
                )

            case .threads(.delegate(.didClearActiveThread)):
                state.activeThread = nil
                state.isDrawerPresented = true
                state.isFileBrowserPresented = false
                return .merge(
                    .send(.approval(.dismiss)),
                    .send(.chat(.setApprovalLocked(false))),
                    .send(.chat(.setActiveThread(nil))),
                    .send(.terminal(.setActiveThread(nil))),
                    .send(.fileBrowser(.setActiveThread(nil)))
                )

            case .threads(.delegate(.refreshRequested)):
                return .send(.syncNow)

            case .chat(.delegate(.approvalRequired(let approval))):
                if let idx = state.threads.items.firstIndex(where: { $0.threadId == approval.threadId }) {
                    state.threads.items[idx].pendingApprovalCount = max(
                        1,
                        state.threads.items[idx].pendingApprovalCount
                    )
                }
                return .merge(
                    .send(.approval(.present(approval))),
                    .send(.chat(.setApprovalLocked(true))),
                    .send(.threads(.refresh))
                )

            case .chat(.delegate(.approvalResolved(_, _))):
                if let threadId = state.approval.currentApproval?.threadId,
                   let idx = state.threads.items.firstIndex(where: { $0.threadId == threadId })
                {
                    state.threads.items[idx].pendingApprovalCount = 0
                }
                return .merge(
                    .send(.approval(.dismiss)),
                    .send(.chat(.setApprovalLocked(false))),
                    .send(.threads(.refresh))
                )

            case .chat(.delegate(.streamConnectionChanged(let streamConnectionState))):
                state.streamConnectionState = streamConnectionState
                recalculateConnectionState(state: &state)
                return .none

            case .chat(.delegate(.jobFinished(_, _))):
                return .none

            case .fileBrowser(.delegate(.openInTerminal(let path))):
                state.isFileBrowserPresented = false
                return .merge(
                    .send(.terminal(.setPresented(true))),
                    .send(.terminal(.enqueueInput("cd \(shellQuoted(path))\n")))
                )

            case .settings(.saveFinished):
                return .merge(.send(.healthCheckNow), .run { _ in
                    await RemotePushRegistrationService.flushPendingRegistration()
                })

            case .settings(.delegate(.didRestoreArchivedThread)):
                return .send(.threads(.refresh))

            case .threads(.pinResponse(_, .failure(let error))):
                state.chat.errorMessage = "持续展示未能更新：" + error.localizedDescription
                return .none
            case .threads, .chat, .terminal, .fileBrowser, .approval, .settings, .mobileInbox:
                return .none
            }
        }
    }

    private func syncLoop() -> Effect<Action> {
        .merge(.run { send in
            @Dependency(\.threadSyncClient) var sync
            @Dependency(\.continuousClock) var clock
            if let cached = try? await sync.cached() { await send(.syncCached(cached)) }
            while !Task.isCancelled {
                await send(.syncNow)
                try await clock.sleep(for: .seconds(20))
            }
        }, .run { send in
            @Dependency(\.threadSyncClient) var sync
            @Dependency(\.continuousClock) var clock
            while !Task.isCancelled {
                do { for try await _ in sync.hints() { await send(.syncNow) } }
                catch is CancellationError { return }
                catch { /* The durable cursor poll remains the recovery path. */ }
                try await clock.sleep(for: .seconds(5))
            }
        }).cancellable(id: CancelID.syncLoop, cancelInFlight: true)
    }

    private func refreshCachedChat(state: State, changed: [String]) -> Effect<Action> {
        guard let id = state.activeThread?.threadId, changed.contains(id), !state.chat.isStreaming else { return .none }
        return .run { send in
            @Dependency(\.threadSyncClient) var sync
            if let events = try? await sync.cachedEvents(id) {
                await send(.chat(.threadHistoryCacheResponse(threadId: id, .success(events))))
                try? await sync.markRead(id)
            }
        }
    }

    private func shouldEnterCheckingState(_ reachability: WorkerReachability) -> Bool {
        switch reachability {
        case .unknown, .unreachable:
            return true
        case .checking, .reachable:
            return false
        }
    }

    private func recalculateConnectionState(state: inout State) {
        switch state.workerReachability {
        case .unknown:
            state.connectionState = .disconnected

        case .checking:
            state.connectionState = .connecting

        case .unreachable(let message):
            state.connectionState = .failed(message)

        case .reachable:
            switch state.streamConnectionState {
            case .idle, .connected:
                state.connectionState = .connected
            case .connecting:
                state.connectionState = .connecting
            case .failed(let message):
                state.connectionState = .failed("实时流连接失败：\(message)")
            }
        }
    }

    private func shellQuoted(_ path: String) -> String {
        if path.isEmpty {
            return "''"
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
