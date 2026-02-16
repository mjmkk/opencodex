//
//  SSEClient.swift
//  CodexWorker
//
//  SSE 客户端协议 - TCA Dependency
//

import ComposableArchitecture
import EventSource
import Foundation

// MARK: - SSE 客户端协议

/// SSE 客户端协议（支持 TCA 依赖注入）
///
/// 封装 EventSource 库，提供类型安全的 SSE 事件流
public struct SSEClient: DependencyKey, Sendable {
    // MARK: - SSE 操作

    /// 订阅任务事件流
    ///
    /// - Parameters:
    ///   - jobId: 任务 ID
    ///   - cursor: 游标（从哪个序列号开始）
    /// - Returns: 事件异步流
    public var subscribe: @Sendable (_ jobId: String, _ cursor: Int) async throws -> AsyncStream<EventEnvelope>

    /// 取消订阅
    public var cancel: @Sendable () -> Void

    // MARK: - DependencyKey

    public static let liveValue = SSEClient.live
    public static let testValue = SSEClient.mock
    public static let previewValue = SSEClient.mock
}

// MARK: - Dependency Values

extension DependencyValues {
    public var sseClient: SSEClient {
        get { self[SSEClient.self] }
        set { self[SSEClient.self] = newValue }
    }
}

// MARK: - Live Implementation

extension SSEClient {
    /// 创建真实 SSE 客户端
    public static var live: SSEClient {
        let impl = LiveSSEClient()
        return SSEClient(
            subscribe: { try await impl.subscribe(jobId: $0, cursor: $1) },
            cancel: {
                Task {
                    await impl.cancel()
                }
            }
        )
    }
}

// MARK: - Live SSE Client Implementation

/// 真实 SSE 客户端实现
actor LiveSSEClient {
    /// 当前活跃的任务
    private var activeTask: Task<Void, Never>?

    /// 当前连接状态
    private(set) var connectionState: SSEConnectionState = .disconnected

    /// JSON 解码器
    private let decoder = JSONDecoder()

    /// 重连策略
    private let reconnectStrategy = ReconnectStrategy()

    // MARK: - 订阅

    /// 订阅任务事件流
    func subscribe(jobId: String, cursor: Int) async throws -> AsyncStream<EventEnvelope> {
        // 取消之前的订阅
        cancel()

        return AsyncStream { continuation in
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.startEventStream(
                    jobId: jobId,
                    cursor: cursor,
                    continuation: continuation
                )
            }

            activeTask = task

            // 设置清理回调
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.cancel()
                }
            }
        }
    }

    /// 启动事件流
    private func startEventStream(
        jobId: String,
        cursor: Int,
        continuation: AsyncStream<EventEnvelope>.Continuation
    ) async {
        var attempt = 0

        while !Task.isCancelled {
            do {
                attempt += 1
                connectionState = .connecting

                // 获取配置
                guard let config = WorkerConfiguration.load() else {
                    continuation.yield(
                        EventEnvelope(
                            type: "error",
                            ts: ISO8601DateFormatter().string(from: Date()),
                            jobId: jobId,
                            seq: -1,
                            payload: ["message": .string("未配置 Worker 连接")]
                        )
                    )
                    continuation.finish()
                    return
                }

                // 构建请求
                let urlString = "\(config.baseURL)/v1/jobs/\(jobId)/events?cursor=\(cursor)"
                guard let url = URL(string: urlString) else {
                    throw CodexError.invalidState
                }

                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                if let token = config.token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                // 创建 EventSource
                let eventSource = EventSource(timeoutInterval: 300)
                let dataTask = eventSource.dataTask(for: request)

                connectionState = .connected
                attempt = 0  // 重置重连计数

                // 处理事件流
                for await event in dataTask.events() {
                    if Task.isCancelled { break }

                    switch event {
                    case let .event(serverEvent):
                        if let envelope = parseEvent(serverEvent) {
                            continuation.yield(envelope)

                            // 检查是否为终态
                            if envelope.type == "job.finished" {
                                connectionState = .disconnected
                                continuation.finish()
                                return
                            }
                        }

                    case .open:
                        connectionState = .connected

                    case let .error(error):
                        handleError(error, jobId: jobId)

                    case .closed:
                        connectionState = .disconnected
                        // 非终态关闭，尝试重连
                        break
                    }
                }

                // 如果流结束但未收到终态，可能是连接断开
                // 由外层重试逻辑处理
                connectionState = .disconnected

            } catch {
                handleError(error, jobId: jobId)
                // 检查是否需要重连
                if attempt < reconnectStrategy.maxAttempts {
                    let delay = reconnectStrategy.delay(for: attempt)
                    connectionState = .reconnecting(attempt: attempt)

                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    // 重连失败，发送错误事件
                    connectionState = .failed(error.localizedDescription)
                    continuation.yield(
                        EventEnvelope(
                            type: "error",
                            ts: ISO8601DateFormatter().string(from: Date()),
                            jobId: jobId,
                            seq: -1,
                            payload: ["message": .string("连接失败: \(error.localizedDescription)")]
                        )
                    )
                    continuation.finish()
                    return
                }
            }
        }
    }

    /// 解析 SSE 事件
    private func parseEvent(_ event: EVEvent) -> EventEnvelope? {
        guard let raw = event.data else { return nil }
        guard let data = raw.data(using: .utf8) else { return nil }

        do {
            return try decoder.decode(EventEnvelope.self, from: data)
        } catch {
            print("[SSEClient] 解析事件失败: \(error)")
            print("[SSEClient] 原始数据: \(raw)")
            return nil
        }
    }

    /// 处理错误
    private func handleError(_ error: Error, jobId: String) {
        print("[SSEClient] 错误: \(error.localizedDescription)")
    }

    /// 取消订阅
    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        connectionState = .disconnected
    }
}

// MARK: - SSE 连接状态

/// SSE 连接状态
enum SSEConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

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

    var isConnected: Bool {
        self == .connected
    }
}

// MARK: - 重连策略

/// 重连策略配置
struct ReconnectStrategy: Sendable {
    /// 最大重连次数
    var maxAttempts: Int = 10

    /// 基础延迟（秒）
    var baseDelay: TimeInterval = 1.0

    /// 最大延迟（秒）
    var maxDelay: TimeInterval = 30.0

    /// 计算重连延迟（指数退避）
    func delay(for attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))
        return min(exponential, maxDelay)
    }
}

// MARK: - Mock Implementation

extension SSEClient {
    /// Mock 客户端（用于测试和预览）
    public static var mock: SSEClient {
        SSEClient(
            subscribe: { jobId, _ in
                AsyncStream { continuation in
                    // 模拟事件流
                    Task {
                        // 模拟任务状态
                        continuation.yield(
                            EventEnvelope(
                                type: "job.state",
                                ts: ISO8601DateFormatter().string(from: Date()),
                                jobId: jobId,
                                seq: 0,
                                payload: ["state": .string("RUNNING")]
                            )
                        )

                        // 模拟 AI 消息增量
                        let messageParts = ["Hello", "! ", "This", " is", " a", " test", " message", "."]
                        for (index, part) in messageParts.enumerated() {
                            try? await Task.sleep(for: .milliseconds(200))
                            continuation.yield(
                                EventEnvelope(
                                    type: "item.agentMessage.delta",
                                    ts: ISO8601DateFormatter().string(from: Date()),
                                    jobId: jobId,
                                    seq: index + 1,
                                    payload: [
                                        "itemId": .string("item_1"),
                                        "delta": .string(part),
                                    ]
                                )
                            )
                        }

                        // 模拟任务完成
                        try? await Task.sleep(for: .milliseconds(500))
                        continuation.yield(
                            EventEnvelope(
                                type: "job.finished",
                                ts: ISO8601DateFormatter().string(from: Date()),
                                jobId: jobId,
                                seq: messageParts.count + 1,
                                payload: ["state": .string("DONE")]
                            )
                        )

                        continuation.finish()
                    }
                }
            },
            cancel: {}
        )
    }
}
