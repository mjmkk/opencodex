//
//  WorkerConfigurationStore.swift
//  CodexWorker
//
//  Worker 配置仓储依赖（TCA）
//

import ComposableArchitecture

/// Worker 配置仓储
///
/// 用途：
/// - 隔离 `UserDefaults` 存取细节
/// - 让 Feature 通过依赖注入读写配置，方便测试
public struct WorkerConfigurationStore: DependencyKey, Sendable {
    public var load: @Sendable () -> WorkerConfiguration?
    public var save: @Sendable (_ configuration: WorkerConfiguration) -> Void
    public var clear: @Sendable () -> Void

    public static let liveValue = WorkerConfigurationStore(
        load: { WorkerConfiguration.load() },
        save: { configuration in
            WorkerConfiguration.save(Self.normalized(configuration))
        },
        clear: { WorkerConfiguration.clear() }
    )

    public static let testValue = WorkerConfigurationStore(
        load: { WorkerConfiguration.default },
        save: { _ in },
        clear: {}
    )

    public static let previewValue = testValue
}

extension DependencyValues {
    public var workerConfigurationStore: WorkerConfigurationStore {
        get { self[WorkerConfigurationStore.self] }
        set { self[WorkerConfigurationStore.self] = newValue }
    }
}

extension WorkerConfigurationStore {
    /// 统一清洗配置，避免无效空格与尾部 `/` 导致 URL 拼接不一致。
    public static func normalized(_ configuration: WorkerConfiguration) -> WorkerConfiguration {
        let trimmedBaseURL = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlash()
        let trimmedToken = configuration.token?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return WorkerConfiguration(
            baseURL: trimmedBaseURL,
            token: (trimmedToken?.isEmpty == true) ? nil : trimmedToken
        )
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var value = self
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
