//
//  Configuration.swift
//  CodexWorker
//
//  Worker 连接配置管理
//

import Foundation

/// Worker 连接配置
///
/// 说明：
/// - `baseURL` 示例：`http://192.168.1.10:8787`
/// - `token` 对应后端 Bearer Token，可为空（后端未开启鉴权时）
public struct WorkerConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var token: String?

    /// 默认配置（开发态）
    public static let `default` = WorkerConfiguration(
        baseURL: "http://127.0.0.1:8787",
        token: nil
    )

    public init(baseURL: String, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }
}

extension WorkerConfiguration {
    private static let storageKey = "codex.worker.configuration"

    /// 加载配置（不存在时返回 nil）
    public static func load() -> WorkerConfiguration? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let config = try? JSONDecoder().decode(WorkerConfiguration.self, from: data)
        else {
            return nil
        }
        return config
    }

    /// 保存配置
    public static func save(_ configuration: WorkerConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 清空配置
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
