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
/// - `model` 为可选模型 ID，留空表示跟随后端默认模型
public struct WorkerConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var token: String?
    public var model: String?

    /// 默认配置（开发态）
    public static let `default` = WorkerConfiguration(
        baseURL: "http://100.83.35.124:8787",
        token: nil,
        model: nil
    )

    public init(baseURL: String, token: String?, model: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.model = model
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
