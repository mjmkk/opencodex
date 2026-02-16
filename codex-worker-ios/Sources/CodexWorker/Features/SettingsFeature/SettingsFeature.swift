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
        public var baseURL = WorkerConfiguration.load()?.baseURL ?? WorkerConfiguration.default.baseURL
        public var token = WorkerConfiguration.load()?.token ?? ""
        public var saveSucceeded = false

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case saveTapped
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .saveTapped:
                let token = state.token.trimmingCharacters(in: .whitespacesAndNewlines)
                WorkerConfiguration.save(
                    .init(
                        baseURL: state.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        token: token.isEmpty ? nil : token
                    )
                )
                state.saveSucceeded = true
                return .none

            case .binding:
                state.saveSucceeded = false
                return .none
            }
        }
    }
}
