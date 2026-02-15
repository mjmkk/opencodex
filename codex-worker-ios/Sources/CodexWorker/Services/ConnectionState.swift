//
//  ConnectionState.swift
//  CodexWorker
//
//  连接状态管理
//

import Foundation
import SwiftUI

// MARK: - 连接状态

/// 全局连接状态
enum ConnectionState: Equatable, Sendable {
    /// 未连接
    case disconnected
    /// 连接中
    case connecting
    /// 已连接
    case connected
    /// 重连中
    case reconnecting(attempt: Int)
    /// 连接失败
    case failed(String)

    // MARK: - 计算属性

    /// 状态标签
    var label: String {
        switch self {
        case .disconnected:
            return "未连接"
        case .connecting:
            return "连接中..."
        case .connected:
            return "已连接"
        case let .reconnecting(attempt):
            return "重连中(\(attempt))..."
        case let .failed(message):
            return "连接失败: \(message)"
        }
    }

    /// 状态颜色
    var color: Color {
        switch self {
        case .disconnected:
            return .gray
        case .connecting, .reconnecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    /// 是否已连接
    var isConnected: Bool {
        self == .connected
    }

    /// 是否正在连接
    var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    /// 是否需要显示状态条
    var shouldShowBanner: Bool {
        self != .connected
    }
}

// MARK: - 连接状态管理器

/// 连接状态管理器（用于跨 Feature 共享状态）
@MainActor
@Observable
final class ConnectionStateManager: ObservableObject {
    /// 当前连接状态
    var state: ConnectionState = .disconnected {
        didSet {
            // 状态变化时可以触发通知等
            print("[ConnectionState] 状态变化: \(oldValue) -> \(state)")
        }
    }

    /// Worker 是否可达
    var isWorkerReachable: Bool = false

    /// 上次成功连接时间
    var lastConnectedAt: Date?

    /// 错误信息
    var lastError: String?

    // MARK: - 状态更新

    /// 更新连接状态
    func updateState(_ newState: ConnectionState) {
        state = newState

        if newState == .connected {
            lastConnectedAt = Date()
            lastError = nil
            isWorkerReachable = true
        }

        if case let .failed(error) = newState {
            lastError = error
            isWorkerReachable = false
        }
    }

    /// 重置状态
    func reset() {
        state = .disconnected
        isWorkerReachable = false
        lastError = nil
    }
}

// MARK: - 连接检查器

/// 连接检查器
actor ConnectionChecker {
    private let session: URLSession
    private var checkTask: Task<Void, Never>?

    /// 检查间隔（秒）
    var checkInterval: TimeInterval = 30

    /// 连接状态回调
    var onStateChanged: (@Sendable (ConnectionState) -> Void)?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - 健康检查

    /// 执行单次健康检查
    func checkHealth() async -> ConnectionState {
        guard let config = WorkerConfiguration.load() else {
            return .failed("未配置")
        }

        let urlString = "\(config.baseURL)/health"
        guard let url = URL(string: urlString) else {
            return .failed("URL 无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("响应无效")
            }

            if httpResponse.statusCode == 200 {
                return .connected
            } else if httpResponse.statusCode == 401 {
                return .failed("认证失败")
            } else {
                return .failed("HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 定时检查

    /// 启动定时健康检查
    func startPeriodicCheck() {
        stopPeriodicCheck()

        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                if let state = await self?.checkHealth() {
                    await self?.onStateChanged?(state)
                }

                try? await Task.sleep(for: .seconds(self?.checkInterval ?? 30))
            }
        }
    }

    /// 停止定时检查
    func stopPeriodicCheck() {
        checkTask?.cancel()
        checkTask = nil
    }
}
