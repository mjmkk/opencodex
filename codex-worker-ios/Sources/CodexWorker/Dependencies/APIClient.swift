//
//  APIClient.swift
//  CodexWorker
//
//  REST API 客户端协议 - TCA Dependency
//

import ComposableArchitecture
import Foundation
import OSLog

// MARK: - API 客户端协议

/// API 客户端协议（支持 TCA 依赖注入）
///
/// 定义了与后端 Worker 交互的所有 REST API 操作
public struct APIClient: DependencyKey, Sendable {
    // MARK: - API 操作

    /// 列出可用项目
    public var listProjects: @Sendable () async throws -> [Project]

    /// 列出可选模型
    public var listModels: @Sendable () async throws -> [WorkerModel]

    /// 创建线程
    public var createThread: @Sendable (_ request: CreateThreadRequest) async throws -> Thread

    /// 列出线程
    public var listThreads: @Sendable (_ archived: Bool?) async throws -> ThreadsListResponse

    /// 归档线程
    public var archiveThread: @Sendable (_ threadId: String) async throws -> ArchiveThreadResponse

    /// 恢复归档线程
    public var unarchiveThread: @Sendable (_ threadId: String) async throws -> ArchiveThreadResponse

    /// 激活线程
    public var activateThread: @Sendable (_ threadId: String) async throws -> Thread

    /// 获取线程历史事件分页（线程级游标）
    public var mirrorIndex: @Sendable () async throws -> MirrorIndex = { throw CodexError.invalidState }
    public var mirrorBody: @Sendable (String, Bool, Int, String?) async throws -> MirrorBody = { _, _, _, _ in throw CodexError.invalidState }
    public var nativeRequests: @Sendable () async throws -> NativeRequestList = { throw CodexError.invalidState }
    public var goalOverview: @Sendable () async throws -> JSONValue = { throw CodexError.invalidState }
    public var readNativeRequest: @Sendable (NativeRequestSelection) async throws -> NativeRemoteRequest = { _ in throw CodexError.invalidState }
    public var respondNativeRequest: @Sendable (NativeRequestSelection) async throws -> NativeRemoteRequest = { _ in throw CodexError.invalidState }

    /// 查询线程终端状态
    public var getThreadTerminal: @Sendable (_ threadId: String) async throws -> ThreadTerminalStatusResponse

    /// 打开线程终端
    public var openThreadTerminal: @Sendable (_ threadId: String, _ request: ThreadTerminalOpenRequest) async throws -> ThreadTerminalOpenResponse

    /// 调整终端窗口尺寸
    public var resizeTerminal: @Sendable (_ sessionId: String, _ request: TerminalResizeRequest) async throws -> TerminalResizeResponse

    /// 关闭终端会话
    public var closeTerminal: @Sendable (_ sessionId: String, _ request: TerminalCloseRequest) async throws -> TerminalCloseResponse

    /// 获取线程可见文件根目录
    public var listThreadFsRoots: @Sendable (_ threadId: String) async throws -> FileSystemRootsResponse

    /// 解析文件引用（path:line）
    public var resolveThreadFsReference: @Sendable (_ threadId: String, _ ref: String) async throws -> FileResolveResponse

    /// 列出目录（分页）
    public var listThreadFsTree: @Sendable (_ threadId: String, _ fsPath: String?, _ cursor: Int?, _ limit: Int?) async throws -> FileTreeResponse

    /// 读取文件内容（按行）
    public var getThreadFsFile: @Sendable (_ threadId: String, _ fsPath: String, _ fromLine: Int?, _ toLine: Int?) async throws -> FileContentResponse

    /// 获取文件元信息
    public var getThreadFsStat: @Sendable (_ threadId: String, _ fsPath: String) async throws -> FileStatResponse

    /// 文本搜索（分页）
    public var searchThreadFs: @Sendable (_ threadId: String, _ query: String, _ fsPath: String?, _ cursor: Int?, _ limit: Int?) async throws -> FileSearchResponse

    /// 写入文件
    public var writeThreadFsFile: @Sendable (_ threadId: String, _ request: FileWriteRequest) async throws -> FileWriteResponse

    /// 发送消息（创建 Turn）

    /// 获取任务快照

    /// 获取任务事件列表（非 SSE）

    /// 提交审批决策

    /// 取消任务

    /// 健康检查
    public var healthCheck: @Sendable () async throws -> HealthCheckResponse

    // MARK: - DependencyKey

    public static let liveValue: APIClient = APIClient.live
    public static let testValue: APIClient = APIClient.live
    public static let previewValue: APIClient = APIClient.live
}

// MARK: - Dependency Values

extension DependencyValues {
    public var apiClient: APIClient {
        get { self[APIClient.self] }
        set { self[APIClient.self] = newValue }
    }
}

// MARK: - 健康检查响应

/// 健康检查响应
public struct HealthCheckResponse: Codable, Sendable {
    public let status: String
    public let authEnabled: Bool
}

// MARK: - Live Implementation

extension APIClient {
    /// 创建真实 API 客户端
    public static var live: APIClient {
        let impl = LiveAPIClient()
        return APIClient(
            listProjects: { try await impl.listProjects() },
            listModels: { try await impl.listModels() },
            createThread: { try await impl.createThread(request: $0) },
            listThreads: { try await impl.listThreads(archived: $0) },
            archiveThread: { try await impl.archiveThread(threadId: $0) },
            unarchiveThread: { try await impl.unarchiveThread(threadId: $0) },
            activateThread: { try await impl.activateThread(threadId: $0) },
            mirrorIndex: { try await impl.mirrorIndex() },
            mirrorBody: { try await impl.mirrorBody($0, offline: $1, offset: $2, snapshot: $3) },
            nativeRequests: { try await impl.nativeRequests() },
            goalOverview: { try await impl.goalOverview() },
            readNativeRequest: { try await impl.nativeRequest($0, operation: "read") },
            respondNativeRequest: { try await impl.nativeRequest($0, operation: "respond") },
            getThreadTerminal: { try await impl.getThreadTerminal(threadId: $0) },
            openThreadTerminal: { try await impl.openThreadTerminal(threadId: $0, request: $1) },
            resizeTerminal: { try await impl.resizeTerminal(sessionId: $0, request: $1) },
            closeTerminal: { try await impl.closeTerminal(sessionId: $0, request: $1) },
            listThreadFsRoots: { try await impl.listThreadFsRoots(threadId: $0) },
            resolveThreadFsReference: { try await impl.resolveThreadFsReference(threadId: $0, ref: $1) },
            listThreadFsTree: { try await impl.listThreadFsTree(threadId: $0, fsPath: $1, cursor: $2, limit: $3) },
            getThreadFsFile: { try await impl.getThreadFsFile(threadId: $0, fsPath: $1, fromLine: $2, toLine: $3) },
            getThreadFsStat: { try await impl.getThreadFsStat(threadId: $0, fsPath: $1) },
            searchThreadFs: { try await impl.searchThreadFs(threadId: $0, query: $1, fsPath: $2, cursor: $3, limit: $4) },
            writeThreadFsFile: { try await impl.writeThreadFsFile(threadId: $0, request: $1) },
            healthCheck: { try await impl.healthCheck() }
        )
    }
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
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "100")]
        if let snapshot { query.append(.init(name: "snapshot", value: snapshot)) }
        let request = try buildRequest(url: buildURL(path: "/v1/mirror/threads/" + component, queryItems: query))
        return try await performRequest(request, preservingKeys: true)
    }

    func listProjects() async throws -> [Project] {
        let url = try buildURL(path: "/v1/projects")
        let request = try buildRequest(url: url)
        let response: ProjectsListResponse = try await performRequest(request)
        return response.data
    }

    func listModels() async throws -> [WorkerModel] {
        let url = try buildURL(path: "/v1/models")
        let request = try buildRequest(url: url)
        let response: WorkerModelsResponse = try await performRequest(request)
        return response.data
    }

    func createThread(request: CreateThreadRequest) async throws -> Thread {
        let url = try buildURL(path: "/v1/threads")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)

        struct CreateThreadResponse: Codable {
            let thread: Thread
        }

        let response: CreateThreadResponse = try await performRequest(urlRequest)
        return response.thread
    }

    func listThreads(archived: Bool?) async throws -> ThreadsListResponse {
        var queryItems: [URLQueryItem] = []
        if let archived {
            queryItems.append(URLQueryItem(name: "archived", value: archived ? "true" : "false"))
        }
        let url = try buildURL(path: "/v1/threads", queryItems: queryItems.isEmpty ? nil : queryItems)
        let request = try buildRequest(url: url)
        let response: ThreadsListResponse = try await performRequest(request)
        logger.debug("listThreads ok, count=\(response.data.count)")
        return response
    }

    func archiveThread(threadId: String) async throws -> ArchiveThreadResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/archive")
        let request = try buildRequest(url: url, method: "POST")
        return try await performRequest(request)
    }

    func unarchiveThread(threadId: String) async throws -> ArchiveThreadResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/unarchive")
        let request = try buildRequest(url: url, method: "POST")
        return try await performRequest(request)
    }

    func activateThread(threadId: String) async throws -> Thread {
        let url = try buildURL(path: "/v1/threads/\(threadId)/activate")
        let request = try buildRequest(url: url, method: "POST")

        struct ActivateResponse: Codable {
            let thread: Thread
        }

        let response: ActivateResponse = try await performRequest(request)
        return response.thread
    }

    func getThreadTerminal(threadId: String) async throws -> ThreadTerminalStatusResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/terminal")
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func openThreadTerminal(threadId: String, request: ThreadTerminalOpenRequest) async throws -> ThreadTerminalOpenResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/terminal/open")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)
        return try await performRequest(urlRequest)
    }

    func resizeTerminal(sessionId: String, request: TerminalResizeRequest) async throws -> TerminalResizeResponse {
        let url = try buildURL(path: "/v1/terminals/\(sessionId)/resize")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)
        return try await performRequest(urlRequest)
    }

    func closeTerminal(sessionId: String, request: TerminalCloseRequest) async throws -> TerminalCloseResponse {
        let url = try buildURL(path: "/v1/terminals/\(sessionId)/close")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)
        return try await performRequest(urlRequest)
    }

    func listThreadFsRoots(threadId: String) async throws -> FileSystemRootsResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/roots")
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func resolveThreadFsReference(threadId: String, ref: String) async throws -> FileResolveResponse {
        let queryItems = [
            URLQueryItem(name: "ref", value: ref),
        ]
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/resolve", queryItems: queryItems)
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func listThreadFsTree(
        threadId: String,
        fsPath: String?,
        cursor: Int?,
        limit: Int?
    ) async throws -> FileTreeResponse {
        var queryItems: [URLQueryItem] = []
        if let fsPath, !fsPath.isEmpty {
            queryItems.append(URLQueryItem(name: "path", value: fsPath))
        }
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/tree", queryItems: queryItems.isEmpty ? nil : queryItems)
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func getThreadFsFile(
        threadId: String,
        fsPath: String,
        fromLine: Int?,
        toLine: Int?
    ) async throws -> FileContentResponse {
        var queryItems = [URLQueryItem(name: "path", value: fsPath)]
        if let fromLine {
            queryItems.append(URLQueryItem(name: "fromLine", value: String(fromLine)))
        }
        if let toLine {
            queryItems.append(URLQueryItem(name: "toLine", value: String(toLine)))
        }
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/file", queryItems: queryItems)
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func getThreadFsStat(threadId: String, fsPath: String) async throws -> FileStatResponse {
        let queryItems = [URLQueryItem(name: "path", value: fsPath)]
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/stat", queryItems: queryItems)
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func searchThreadFs(
        threadId: String,
        query: String,
        fsPath: String?,
        cursor: Int?,
        limit: Int?
    ) async throws -> FileSearchResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
        ]
        if let fsPath, !fsPath.isEmpty {
            queryItems.append(URLQueryItem(name: "path", value: fsPath))
        }
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/search", queryItems: queryItems)
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func writeThreadFsFile(threadId: String, request: FileWriteRequest) async throws -> FileWriteResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/fs/write")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)
        return try await performRequest(urlRequest)
    }

    func nativeRequests() async throws -> NativeRequestList {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/native-requests")), preservingKeys: true)
    }
    func goalOverview() async throws -> JSONValue {
        try await performRequest(buildRequest(url: buildURL(path: "/v1/overview/goals")), preservingKeys: true)
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
