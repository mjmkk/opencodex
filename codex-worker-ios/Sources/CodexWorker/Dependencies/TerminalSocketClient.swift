//
//  TerminalSocketClient.swift
//  CodexWorker
//
//  终端 WebSocket 依赖（TCA）
//

import ComposableArchitecture
import Foundation

public struct TerminalSocketClient: DependencyKey, Sendable {
    /// 连接终端流并返回消息流
    public var subscribe: @Sendable (_ sessionId: String, _ fromSeq: Int?) async throws -> AsyncThrowingStream<TerminalStreamFrame, Error>

    /// 发送输入
    public var sendInput: @Sendable (_ data: String) async throws -> Void

    /// 调整终端尺寸
    public var sendResize: @Sendable (_ cols: Int, _ rows: Int) async throws -> Void

    /// 断开连接
    public var disconnect: @Sendable () async -> Void

    public static let liveValue = TerminalSocketClient.live
    public static let testValue = TerminalSocketClient.mock
    public static let previewValue = TerminalSocketClient.mock
}

extension DependencyValues {
    public var terminalSocketClient: TerminalSocketClient {
        get { self[TerminalSocketClient.self] }
        set { self[TerminalSocketClient.self] = newValue }
    }
}

extension TerminalSocketClient {
    public static var live: TerminalSocketClient {
        let impl = LiveTerminalSocketClient()
        return TerminalSocketClient(
            subscribe: { try await impl.subscribe(sessionId: $0, fromSeq: $1) },
            sendInput: { try await impl.send(.input($0)) },
            sendResize: { try await impl.send(.resize(cols: $0, rows: $1)) },
            disconnect: { await impl.disconnect() }
        )
    }

    public static var mock: TerminalSocketClient {
        TerminalSocketClient(
            subscribe: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(
                        TerminalStreamFrame(
                            type: "ready",
                            seq: -1,
                            data: nil,
                            exitCode: nil,
                            signal: nil,
                            sessionId: "term_mock",
                            threadId: "thread_mock",
                            cwd: "/Users/test/project",
                            code: nil,
                            message: nil,
                            clientTs: nil
                        )
                    )
                }
            },
            sendInput: { _ in },
            sendResize: { _, _ in },
            disconnect: {}
        )
    }
}

actor LiveTerminalSocketClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init() {
        self.session = URLSession(configuration: .default)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func subscribe(sessionId: String, fromSeq: Int?) async throws -> AsyncThrowingStream<TerminalStreamFrame, Error> {
        await disconnect()

        let request = try buildRequest(sessionId: sessionId, fromSeq: fromSeq)
        let task = session.webSocketTask(with: request)
        socketTask = task
        task.resume()

        return AsyncThrowingStream { continuation in
            let receiver = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        if let frame = await self.decodeFrame(from: message) {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            receiveTask = receiver
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
        }
    }

    func send(_ message: TerminalClientMessage) async throws {
        guard let task = socketTask else {
            throw CodexError.invalidState
        }

        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexError.invalidState
        }
        try await task.send(.string(text))
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        if let task = socketTask {
            if let detach = try? encodeDetachMessage() {
                try? await task.send(.string(detach))
            }
            task.cancel(with: .normalClosure, reason: nil)
        }
        socketTask = nil
    }

    private func buildRequest(sessionId: String, fromSeq: Int?) throws -> URLRequest {
        guard let config = WorkerConfiguration.load() else {
            throw CodexError.notConfigured
        }

        guard var components = URLComponents(string: config.baseURL) else {
            throw CodexError.invalidState
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            components.scheme = "ws"
        }

        components.path = "/v1/terminals/\(sessionId)/stream"
        if let fromSeq {
            components.queryItems = [
                URLQueryItem(name: "fromSeq", value: String(fromSeq)),
            ]
        } else {
            components.queryItems = nil
        }

        guard let url = components.url else {
            throw CodexError.invalidState
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func decodeFrame(from message: URLSessionWebSocketTask.Message) -> TerminalStreamFrame? {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return nil
        }

        do {
            return try decoder.decode(TerminalStreamFrame.self, from: data)
        } catch {
            return nil
        }
    }

    private func encodeDetachMessage() throws -> String {
        let data = try encoder.encode(TerminalClientMessage.detach)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexError.invalidState
        }
        return text
    }
}
