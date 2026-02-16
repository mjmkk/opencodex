//
//  APIClient.swift
//  CodexWorker
//
//  REST API 客户端协议 - TCA Dependency
//

import ComposableArchitecture
import Foundation

// MARK: - API 客户端协议

/// API 客户端协议（支持 TCA 依赖注入）
///
/// 定义了与后端 Worker 交互的所有 REST API 操作
public struct APIClient: DependencyKey, Sendable {
    // MARK: - API 操作

    /// 列出可用项目
    public var listProjects: @Sendable () async throws -> [Project]

    /// 创建线程
    public var createThread: @Sendable (_ request: CreateThreadRequest) async throws -> Thread

    /// 列出线程
    public var listThreads: @Sendable () async throws -> ThreadsListResponse

    /// 激活线程
    public var activateThread: @Sendable (_ threadId: String) async throws -> Thread

    /// 获取线程历史事件
    public var listThreadEvents: @Sendable (_ threadId: String) async throws -> [EventEnvelope]

    /// 发送消息（创建 Turn）
    public var startTurn: @Sendable (_ threadId: String, _ request: StartTurnRequest) async throws -> StartTurnResponse

    /// 获取任务快照
    public var getJob: @Sendable (_ jobId: String) async throws -> Job

    /// 获取任务事件列表（非 SSE）
    public var listEvents: @Sendable (_ jobId: String, _ cursor: Int?) async throws -> EventsListResponse

    /// 提交审批决策
    public var approve: @Sendable (_ jobId: String, _ request: ApprovalRequest) async throws -> ApprovalResponse

    /// 取消任务
    public var cancel: @Sendable (_ jobId: String) async throws -> CancelResponse

    /// 健康检查
    public var healthCheck: @Sendable () async throws -> HealthCheckResponse

    // MARK: - DependencyKey

    public static let liveValue = APIClient.live
    public static let testValue = APIClient.mock
    public static let previewValue = APIClient.mock
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
            createThread: { try await impl.createThread(request: $0) },
            listThreads: { try await impl.listThreads() },
            activateThread: { try await impl.activateThread(threadId: $0) },
            listThreadEvents: { try await impl.listThreadEvents(threadId: $0) },
            startTurn: { try await impl.startTurn(threadId: $0, request: $1) },
            getJob: { try await impl.getJob(jobId: $0) },
            listEvents: { try await impl.listEvents(jobId: $0, cursor: $1) },
            approve: { try await impl.approve(jobId: $0, request: $1) },
            cancel: { try await impl.cancel(jobId: $0) },
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
        encoder.keyEncodingStrategy = .convertToSnakeCase
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

    /// 执行请求
    private func performRequest<T: Codable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexError.invalidState
            }

            // 检查 HTTP 状态码
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw CodexError.from(statusCode: httpResponse.statusCode, data: data)
            }

            // 解析响应
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                print("[APIClient] 解析错误: \(error)")
                print("[APIClient] 原始数据: \(String(data: data, encoding: .utf8) ?? "nil")")
                throw CodexError.decodingError
            }
        } catch let error as CodexError {
            throw error
        } catch {
            throw CodexError.from(error)
        }
    }

    // MARK: - API 实现

    func listProjects() async throws -> [Project] {
        let url = try buildURL(path: "/v1/projects")
        let request = try buildRequest(url: url)
        let response: ProjectsListResponse = try await performRequest(request)
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

    func listThreads() async throws -> ThreadsListResponse {
        let url = try buildURL(path: "/v1/threads")
        let request = try buildRequest(url: url)
        let response: ThreadsListResponse = try await performRequest(request)
#if DEBUG
        print("[APIClient] listThreads ok, count=\(response.data.count)")
#endif
        return response
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

    func listThreadEvents(threadId: String) async throws -> [EventEnvelope] {
        let url = try buildURL(path: "/v1/threads/\(threadId)/events")
        let request = try buildRequest(url: url)

        struct ThreadEventsResponse: Codable {
            let data: [EventEnvelope]
        }

        let response: ThreadEventsResponse = try await performRequest(request)
        return response.data
    }

    func startTurn(threadId: String, request: StartTurnRequest) async throws -> StartTurnResponse {
        let url = try buildURL(path: "/v1/threads/\(threadId)/turns")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)
        return try await performRequest(urlRequest)
    }

    func getJob(jobId: String) async throws -> Job {
        let url = try buildURL(path: "/v1/jobs/\(jobId)")
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func listEvents(jobId: String, cursor: Int?) async throws -> EventsListResponse {
        var queryItems: [URLQueryItem] = []
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        let url = try buildURL(path: "/v1/jobs/\(jobId)/events", queryItems: queryItems)
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }

    func approve(jobId: String, request: ApprovalRequest) async throws -> ApprovalResponse {
        let url = try buildURL(path: "/v1/jobs/\(jobId)/approve")
        let body = try encoder.encode(request)
        let urlRequest = try buildRequest(url: url, method: "POST", body: body)
        return try await performRequest(urlRequest)
    }

    func cancel(jobId: String) async throws -> CancelResponse {
        let url = try buildURL(path: "/v1/jobs/\(jobId)/cancel")
        let request = try buildRequest(url: url, method: "POST")
        return try await performRequest(request)
    }

    func healthCheck() async throws -> HealthCheckResponse {
        let url = try buildURL(path: "/health")
        let request = try buildRequest(url: url)
        return try await performRequest(request)
    }
}

// MARK: - Mock Implementation

extension APIClient {
    /// Mock 客户端（用于测试和预览）
    public static var mock: APIClient {
        APIClient(
            listProjects: {
                [
                    Project(projectId: "proj_1", projectPath: "/Users/test/project", displayName: "project"),
                ]
            },
            createThread: { _ in
                Thread(
                    threadId: "thread_mock",
                    preview: nil,
                    cwd: "/Users/test/project",
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    updatedAt: ISO8601DateFormatter().string(from: Date()),
                    modelProvider: "openai"
                )
            },
            listThreads: {
                ThreadsListResponse(
                    data: [
                        Thread(
                            threadId: "thread_mock",
                            preview: "这是一个测试线程",
                            cwd: "/Users/test/project",
                            createdAt: ISO8601DateFormatter().string(from: Date()),
                            updatedAt: ISO8601DateFormatter().string(from: Date()),
                            modelProvider: "openai"
                        ),
                    ],
                    nextCursor: nil
                )
            },
            activateThread: { threadId in
                Thread(
                    threadId: threadId,
                    preview: nil,
                    cwd: "/Users/test/project",
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    updatedAt: ISO8601DateFormatter().string(from: Date()),
                    modelProvider: "openai"
                )
            },
            listThreadEvents: { _ in [] },
            startTurn: { threadId, _ in
                StartTurnResponse(
                    jobId: "job_mock",
                    state: "RUNNING",
                    threadId: threadId,
                    turnId: "turn_mock"
                )
            },
            getJob: { jobId in
                Job(
                    jobId: jobId,
                    threadId: "thread_mock",
                    turnId: "turn_mock",
                    state: .running,
                    pendingApprovalCount: 0,
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    updatedAt: ISO8601DateFormatter().string(from: Date()),
                    terminalAt: nil,
                    errorMessage: nil
                )
            },
            listEvents: { _, _ in
                EventsListResponse(data: [], nextCursor: 0, firstSeq: 0, job: nil)
            },
            approve: { jobId, request in
                ApprovalResponse(approvalId: request.approvalId, status: "submitted", decision: request.decision)
            },
            cancel: { jobId in
                CancelResponse(jobId: jobId, state: "CANCELLED")
            },
            healthCheck: {
                HealthCheckResponse(status: "ok", authEnabled: false)
            }
        )
    }
}
