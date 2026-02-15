//
//  AppFeature.swift
//  CodexWorker
//
//  根 Feature：承载全局状态与路由
//

import ComposableArchitecture

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var connectionState: ConnectionState = .disconnected
        var threads = ThreadsFeature.State()
        var chat = ChatFeature.State()
        var approval = ApprovalFeature.State()
        var settings = SettingsFeature.State()
        var activeThread: Thread?
    }

    enum Action {
        case onAppear
        case threads(ThreadsFeature.Action)
        case chat(ChatFeature.Action)
        case approval(ApprovalFeature.Action)
        case settings(SettingsFeature.Action)
        case setConnectionState(ConnectionState)
    }

    var body: some ReducerOf<Self> {
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
                return .none

            case .setConnectionState(let newState):
                state.connectionState = newState
                return .none

            case .threads(.delegate(.didActivateThread(let thread))):
                state.activeThread = thread
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

            case .threads, .chat, .approval, .settings:
                return .none
            }
        }
    }
}
