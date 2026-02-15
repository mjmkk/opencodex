//
//  SettingsFeature.swift
//  CodexWorker
//
//  设置占位 Feature（里程碑 1）
//

import ComposableArchitecture

@Reducer
struct SettingsFeature {
    @ObservableState
    struct State: Equatable {
        var baseURL = WorkerConfiguration.load()?.baseURL ?? WorkerConfiguration.default.baseURL
        var token = WorkerConfiguration.load()?.token ?? ""
        var saveSucceeded = false
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case saveTapped
    }

    var body: some ReducerOf<Self> {
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
