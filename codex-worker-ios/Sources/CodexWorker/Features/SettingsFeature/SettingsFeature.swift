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

    public enum Action {
        case baseURLChanged(String)
        case tokenChanged(String)
        case saveTapped
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .baseURLChanged(let value):
                state.baseURL = value
                state.saveSucceeded = false
                return .none

            case .tokenChanged(let value):
                state.token = value
                state.saveSucceeded = false
                return .none

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
            }
        }
    }
}
