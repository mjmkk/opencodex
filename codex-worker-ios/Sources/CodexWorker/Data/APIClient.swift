//
//  APIClient.swift
//  CodexWorker
//
//  REST API 客户端
//

import Foundation
import OSLog

// MARK: - API 客户端协议

/// 手机端用到的 opencodex-mobile REST 接口
public struct APIClient: Sendable {
    // MARK: - API 操作

    public var mirrorIndex: @Sendable () async throws -> MirrorIndex = { throw CodexError.invalidState }
    public var mirrorBody: @Sendable (String, Bool, Int, String?) async throws -> MirrorBody = { _, _, _, _ in throw CodexError.invalidState }
    /// AGT-26 S6：按窗口读正文。offset 为 nil 时取最新的 limit 条（tail），否则从 offset 往后取 limit 条；都不带工具调用列表
    public var mirrorWindow: @Sendable (String, Bool, Int?, Int) async throws -> MirrorBody = { _, _, _, _ in throw CodexError.invalidState }
    public var nativeRequests: @Sendable () async throws -> NativeRequestList = { throw CodexError.invalidState }

    /// AGT-26 S6：Goal 下的成员树（思考线程 / Master / Worker），每个成员带 harness 和机器
    public var harnessTree: @Sendable () async throws -> JSONValue = { throw CodexError.invalidState }
    /// AGT-26 S6：Claude 会话的统一消息模型（Codex 线程服务端会返回 409，客户端改走 Mirror）
    public var harnessThread: @Sendable (String) async throws -> JSONValue = { _ in throw CodexError.invalidState }
    /// AGT-26 S6：Codex 线程最近的消息，服务端直接读会话文件，不占云端读取额度，可以几秒问一次
    public var harnessLive: @Sendable (String) async throws -> JSONValue = { _ in throw CodexError.invalidState }
    public var harnessSend: @Sendable (String, String, String) async throws -> JSONValue = { _, _, _ in throw CodexError.invalidState }
    public var harnessRename: @Sendable (String?, String?, String, Int) async throws -> JSONValue = { _, _, _, _ in throw CodexError.invalidState }
    public var nativeControl: @Sendable (String) async throws -> JSONValue = { _ in throw CodexError.invalidState }
    public var nativeInput: @Sendable (String, String, String, String, String) async throws -> JSONValue = { _, _, _, _, _ in throw CodexError.invalidState }
    public var nativeSubmission: @Sendable (String, String) async throws -> JSONValue = { _, _ in throw CodexError.invalidState }
    public var readNativeRequest: @Sendable (NativeRequestSelection) async throws -> NativeRemoteRequest = { _ in throw CodexError.invalidState }
    public var respondNativeRequest: @Sendable (NativeRequestSelection) async throws -> NativeRemoteRequest = { _ in throw CodexError.invalidState }

    public var healthCheck: @Sendable () async throws -> HealthCheckResponse
}

// MARK: - 健康检查响应

/// 健康检查响应
public struct HealthCheckResponse: Codable, Sendable {
    public let status: String
    public let authEnabled: Bool
}

// MARK: - Live Implementation

extension APIClient {
    /// 全 App 共用一个实例（一个 URLSession）
    public static let live: APIClient = {
        let impl = LiveAPIClient()
        return APIClient(
            mirrorIndex: { try await impl.mirrorIndex() },
            mirrorBody: { try await impl.mirrorBody($0, offline: $1, offset: $2, snapshot: $3) },
            mirrorWindow: { try await impl.mirrorWindow($0, offline: $1, offset: $2, limit: $3) },
            nativeRequests: { try await impl.nativeRequests() },
            harnessTree: { try await impl.harnessTree() },
            harnessThread: { try await impl.harnessThread($0) },
            harnessLive: { try await impl.harnessLive($0) },
            harnessSend: { try await impl.harnessSend(id: $0, text: $1, clientMessageId: $2) },
            harnessRename: { try await impl.harnessRename(threadId: $0, issueId: $1, name: $2, revision: $3) },
            nativeControl: { try await impl.nativeControl($0) },
            nativeInput: { try await impl.nativeInput($0, text: $1, submissionId: $2, receipt: $3, version: $4) },
            nativeSubmission: { try await impl.nativeSubmission($0, submissionId: $1) },
            readNativeRequest: { try await impl.nativeRequest($0, operation: "read") },
            respondNativeRequest: { try await impl.nativeRequest($0, operation: "respond") },
            healthCheck: { try await impl.healthCheck() }
        )
    }()
}

// MARK: - Live API Client Implementation

/// 真实 API 客户端实现
actor LiveAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "com.opencodex", category: "APIClient")

    init() {
        // 配置 URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        // 配置解码器
        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // 配置编码器
        self.encoder = JSONEncoder()
        // 后端当前请求体契约使用 camelCase，避免自动转换导致字段不匹配。
        encoder.keyEncodingStrategy = .useDefaultKeys
    }

    // MARK: - 基础请求方法

    /// 获取配置（从 UserDefaults 或 Environment）
    private func getConfiguration() throws -> WorkerConfiguration {
        guard let config = WorkerConfiguration.load() else {
            throw CodexError.notConfigured
        }
        return config
    }

    /// 构建请求 URL
    private func buildURL(path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        let config = try getConfiguration()
        var components = URLComponents(string: "\(config.baseURL)\(path)")
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw CodexError.invalidState
        }
        return url
    }

    /// 构建 URLRequest
    private func buildRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil
    ) throws -> URLRequest {
        let config = try getConfiguration()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // 添加鉴权 Token
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = body
        return request
    }

    /// 执行请求（带指数退避重试，针对瞬态错误最多重试 2 次）
    private func performRequest<T: Codable>(_ request: URLRequest, preservingKeys: Bool = false) async throws -> T {
        // A timed-out write may already have reached the original thread.
        // Only reads are automatically retried; the UI keeps uncertain writes visible.
        let maxRetries = request.httpMethod == "GET" ? 2 : 0
        var lastTransientError: CodexError?

        for attempt in 0 ... maxRetries {
            if attempt > 0 {
                let delaySecs = min(pow(2.0, Double(attempt - 1)), 8.0)
                logger.warning("[\(attempt)/\(maxRetries)] 瞬态错误，\(delaySecs)s 后重试: \(String(describing: lastTransientError))")
                // Task.sleep 会在 Task 取消时抛出 CancellationError，无需额外处理
                try await Task.sleep(for: .seconds(delaySecs))
            }

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CodexError.invalidState
                }

                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    throw CodexError.from(statusCode: httpResponse.statusCode, data: data)
                }

                do {
                    return try (preservingKeys ? JSONDecoder() : decoder).decode(T.self, from: data)
                } catch {
                    logger.error("解析错误: \(error)")
                    logger.error("响应解析失败，字节数: \(data.count)")
                    throw CodexError.decodingError
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexError where error.isTransient && attempt < maxRetries {
                lastTransientError = error
            } catch let error as CodexError {
                throw error
            } catch {
                throw CodexError.from(error)
            }
        }

        throw lastTransientError ?? CodexError.unknown("请求重试耗尽")
    }

    // MARK: - API 实现

    func mirrorIndex() async throws -> MirrorIndex {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/mirror/threads")), preservingKeys: true)
    }

    func mirrorBody(_ threadID: String, offline: Bool, offset: Int, snapshot: String?) async throws -> MirrorBody {
        guard let component = threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw CodexError.invalidState }
        var query = [URLQueryItem(name: "offline", value: offline ? "true" : "false"),
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "100"),
            // 界面不显示工具调用列表；服务端不分页，长线程每页会重复带几 MB
            URLQueryItem(name: "items", value: "false")]
        if let snapshot { query.append(.init(name: "snapshot", value: snapshot)) }
        let request = try buildRequest(url: buildURL(path: "/v1/mirror/threads/" + component, queryItems: query))
        return try await performRequest(request, preservingKeys: true)
    }

    func mirrorWindow(_ threadID: String, offline: Bool, offset: Int?, limit: Int) async throws -> MirrorBody {
        guard let component = threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw CodexError.invalidState }
        var query = [URLQueryItem(name: "offline", value: offline ? "true" : "false"),
            URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "items", value: "false")]
        if let offset { query.append(.init(name: "offset", value: String(offset))) }
        else { query.append(.init(name: "tail", value: "true")) }
        let request = try buildRequest(url: buildURL(path: "/v1/mirror/threads/" + component, queryItems: query))
        return try await performRequest(request, preservingKeys: true)
    }

    func nativeRequests() async throws -> NativeRequestList {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/native-requests")), preservingKeys: true)
    }
    func harnessThread(_ id: String) async throws -> JSONValue {
        // 查询参数必须走 queryItems：buildURL 会用 queryItems 覆盖 path 里手写的 ?id=
        try await performRequest(buildRequest(url: buildURL(path: "/v1/harness/thread",
                                                            queryItems: [URLQueryItem(name: "id", value: id)])),
                                 preservingKeys: true)
    }
    func harnessLive(_ id: String) async throws -> JSONValue {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/harness/live",
                                                            queryItems: [URLQueryItem(name: "id", value: id)])),
                                 preservingKeys: true)
    }
    /// Codex 线程的原生控制通道（服务端 native-control-route）：先读当前观测，再带着 receipt/version 发文字。
    /// 服务端写入前会落一条持久意图，同一个 submission_id 永远不会发第二次
    func nativeControl(_ threadId: String) async throws -> JSONValue {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/native-threads/\(threadId)/control")),
                                 preservingKeys: true)
    }
    func nativeInput(_ threadId: String, text: String, submissionId: String,
                     receipt: String, version: String) async throws -> JSONValue {
        let body = try JSONSerialization.data(withJSONObject: [
            "submission_id": submissionId, "control_receipt": receipt, "control_version": version, "text": text])
        return try await performRequest(buildRequest(url: buildURL(path: "/v1/native-threads/\(threadId)/input"),
                                                     method: "POST", body: body), preservingKeys: true)
    }
    func nativeSubmission(_ threadId: String, submissionId: String) async throws -> JSONValue {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/native-threads/\(threadId)/submissions/\(submissionId)")),
                                 preservingKeys: true)
    }
    /// POST /v1/harness/send：Human 回复一条线程。client_message_id 由调用方生成，同一个 id 服务端只投递一次
    func harnessSend(id: String, text: String, clientMessageId: String) async throws -> JSONValue {
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "text": text, "client_message_id": clientMessageId])
        return try await performRequest(buildRequest(url: buildURL(path: "/v1/harness/send"), method: "POST", body: body),
                                        preservingKeys: true)
    }
    func harnessRename(threadId: String?, issueId: String?, name: String, revision: Int) async throws -> JSONValue {
        let body = try JSONSerialization.data(withJSONObject: [
            "thread_id": threadId as Any, "issue_id": issueId as Any,
            "new_name": name, "revision": revision].filter { $0.value != nil }
            .mapValues { $0 })
        return try await performRequest(buildRequest(url: buildURL(path: "/v1/harness/rename"), method: "POST", body: body),
                                        preservingKeys: true)
    }

    func harnessTree() async throws -> JSONValue {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/harness/tree")), preservingKeys: true)
    }
    func nativeRequest(_ selection: NativeRequestSelection, operation: String) async throws -> NativeRemoteRequest {
        let body = try JSONEncoder().encode(selection)
        return try await performRequest(buildRequest(url: buildURL(path: "/v1/native-requests/" + operation), method: "POST", body: body), preservingKeys: true)
    }

    func healthCheck() async throws -> HealthCheckResponse {
        let url = try buildURL(path: "/health")
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }
}
