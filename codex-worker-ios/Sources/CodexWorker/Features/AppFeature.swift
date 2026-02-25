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
        public var settings = SettingsFeature.State()
        public var activeThread: Thread?
        public var isDrawerPresented = true
        public var isFileBrowserPresented = false

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
        case settings(SettingsFeature.Action)
        case lifecycleChanged(LifecycleState)
        case setDrawerPresented(Bool)
        case setFileBrowserPresented(Bool)
        case openFileReference(String)
        case setExecutionAccessMode(ExecutionAccessMode)
        case healthCheckNow
        case healthCheckResponse(Result<HealthCheckResponse, CodexError>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.threads, action: \.threads) { ThreadsFeature() }
        Scope(state: \.chat, action: \.chat) { ChatFeature() }
        Scope(state: \.terminal, action: \.terminal) { TerminalFeature() }
        Scope(state: \.fileBrowser, action: \.fileBrowser) { FileBrowserFeature() }
        Scope(state: \.approval, action: \.approval) { ApprovalFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }

        Reduce { state, action in
            switch action {
            case .onAppear:
                if state.activeThread == nil {
                    state.isDrawerPresented = true
                }
                return .merge(
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
                return .cancel(id: CancelID.healthMonitor)

            case .lifecycleChanged(let lifecycle):
                switch lifecycle {
                case .active:
                    return .merge(
                        .send(.healthCheckNow),
                        .send(.chat(.appDidBecomeActive))
                    )
                case .background:
                    return .send(.chat(.appDidEnterBackground))
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
                return .send(.healthCheckNow)

            case .settings(.delegate(.didRestoreArchivedThread)):
                return .send(.threads(.refresh))

            case .threads, .chat, .terminal, .fileBrowser, .approval, .settings:
                return .none
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
