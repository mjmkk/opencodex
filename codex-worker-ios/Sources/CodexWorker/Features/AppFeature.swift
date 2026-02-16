//
//  AppFeature.swift
//  CodexWorker
//
//  根 Feature：承载全局状态与路由
//

import ComposableArchitecture

@Reducer
public struct AppFeature {
    private enum CancelID {
        case healthMonitor
    }

    @ObservableState
    public struct State: Equatable {
        public var connectionState: ConnectionState = .disconnected
        public var threads = ThreadsFeature.State()
        public var chat = ChatFeature.State()
        public var approval = ApprovalFeature.State()
        public var settings = SettingsFeature.State()
        public var activeThread: Thread?
        public var isDrawerPresented = true

        public init() {}
    }

    public enum Action {
        case onAppear
        case onDisappear
        case threads(ThreadsFeature.Action)
        case chat(ChatFeature.Action)
        case approval(ApprovalFeature.Action)
        case settings(SettingsFeature.Action)
        case setConnectionState(ConnectionState)
        case setDrawerPresented(Bool)
        case healthCheckNow
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.threads, action: \.threads) { ThreadsFeature() }
        Scope(state: \.chat, action: \.chat) { ChatFeature() }
        Scope(state: \.approval, action: \.approval) { ApprovalFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }

        Reduce { state, action in
            switch action {
            case .onAppear:
                if WorkerConfiguration.load() == nil {
                    WorkerConfiguration.save(.default)
                }
                if state.activeThread == nil {
                    state.isDrawerPresented = true
                }
                return .merge(
                    .send(.healthCheckNow),
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

            case .healthCheckNow:
                state.connectionState = .connecting
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    do {
                        _ = try await apiClient.healthCheck()
                        await send(.setConnectionState(.connected))
                    } catch {
                        let message = CodexError.from(error).localizedDescription
                        await send(.setConnectionState(.failed(message)))
                    }
                }

            case .setConnectionState(let newState):
                state.connectionState = newState
                return .none

            case .setDrawerPresented(let presented):
                state.isDrawerPresented = presented
                return .none

            case .threads(.delegate(.didActivateThread(let thread))):
                state.activeThread = thread
                state.isDrawerPresented = false
                return .send(.chat(.setActiveThread(thread)))

            case .chat(.delegate(.approvalRequired(let approval))):
                return .merge(
                    .send(.approval(.present(approval))),
                    .send(.chat(.setApprovalLocked(true)))
                )

            case .chat(.delegate(.approvalResolved)):
                return .merge(
                    .send(.approval(.dismiss)),
                    .send(.chat(.setApprovalLocked(false)))
                )

            case .settings(.saveTapped):
                return .send(.healthCheckNow)

            case .threads, .chat, .approval, .settings:
                return .none
            }
        }
    }
}
