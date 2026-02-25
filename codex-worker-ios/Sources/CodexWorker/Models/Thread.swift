//
//  Thread.swift
//  CodexWorker
//
//  线程模型 - 与后端 API 对齐
//

import Foundation

// MARK: - 线程状态

/// 线程状态枚举
public enum ThreadState: String, Codable, Sendable {
    /// 空闲，无活跃任务
    case idle = "idle"
    /// 有活跃任务
    case active = "active"
    /// 已归档
    case archived = "archived"
}

// MARK: - 线程模型

/// 线程 DTO（与后端 API 响应对齐）
///
/// 对应后端 `GET /v1/threads` 返回的线程对象
///
/// 示例 JSON:
/// ```json
/// {
///   "threadId": "thread_abc123",
///   "preview": "最近一条消息预览...",
///   "cwd": "/Users/me/project",
///   "createdAt": "2026-02-15T10:30:00.000Z",
///   "updatedAt": "2026-02-15T12:00:00.000Z",
///   "modelProvider": "openai"
/// }
/// ```
public struct Thread: Identifiable, Codable, Equatable, Sendable {
    /// 线程唯一标识符
    public let threadId: String

    /// 最近消息预览文本
    public var preview: String?

    /// 当前工作目录（Current Working Directory）
    public var cwd: String?

    /// 创建时间（ISO 8601 格式）
    public var createdAt: String?

    /// 更新时间（ISO 8601 格式）
    public var updatedAt: String?

    /// 模型提供者（如 openai、anthropic）
    public var modelProvider: String?

    /// 待处理审批数量（用于线程列表标记）
    public var pendingApprovalCount: Int

    // MARK: - Identifiable

    public var id: String { threadId }

    public init(
        threadId: String,
        preview: String?,
        cwd: String?,
        createdAt: String?,
        updatedAt: String?,
        modelProvider: String?,
        pendingApprovalCount: Int = 0
    ) {
        self.threadId = threadId
        self.preview = preview
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelProvider = modelProvider
        self.pendingApprovalCount = max(0, pendingApprovalCount)
    }

    private enum CodingKeys: String, CodingKey {
        case threadId
        case id
        case thread_id
        case preview
        case cwd
        case createdAt
        case created_at
        case updatedAt
        case updated_at
        case modelProvider
        case model_provider
        case pendingApprovalCount
        case pending_approval_count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard
            let decodedThreadId = try Self.decodeLossyString(
                from: container,
                keys: [.threadId, .id, .thread_id]
            ),
            !decodedThreadId.isEmpty
        else {
            throw DecodingError.keyNotFound(
                CodingKeys.threadId,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "threadId/id 缺失"
                )
            )
        }

        self.threadId = decodedThreadId
        self.preview = Self.decodeLossyString(from: container, keys: [.preview])
        self.cwd = Self.decodeLossyString(from: container, keys: [.cwd])
        self.createdAt = Self.decodeTimestampString(from: container, keys: [.createdAt, .created_at])
        self.updatedAt = Self.decodeTimestampString(from: container, keys: [.updatedAt, .updated_at])
        self.modelProvider = Self.decodeLossyString(from: container, keys: [.modelProvider, .model_provider])
        self.pendingApprovalCount = max(
            0,
            Self.decodeLossyInt(from: container, keys: [.pendingApprovalCount, .pending_approval_count]) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadId, forKey: .threadId)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try container.encode(pendingApprovalCount, forKey: .pendingApprovalCount)
    }

    private static func decodeLossyString(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    private static func decodeTimestampString(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return iso8601String(fromEpoch: Double(value))
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return iso8601String(fromEpoch: value)
            }
        }
        return nil
    }

    private static func decodeLossyInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return intValue
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
        }
        return nil
    }

    private static func iso8601String(fromEpoch epoch: Double) -> String {
        let seconds = epoch > 10_000_000_000 ? (epoch / 1000.0) : epoch
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }
}

// MARK: - 计算属性

extension Thread {
    /// 显示名称（从 cwd 提取最后一段）
    public var displayName: String {
        guard let cwd = cwd else { return "Untitled" }
        let components = cwd.split(separator: "/")
        return components.last.map(String.init) ?? "Untitled"
    }

    /// 最后活跃时间（解析 ISO 8601 时间戳）
    public var lastActiveAt: Date? {
        guard let updatedAt = updatedAt else { return nil }
        return Self.parseISO8601Date(updatedAt)
    }

    /// 创建时间 Date
    public var createdDate: Date? {
        guard let createdAt = createdAt else { return nil }
        return Self.parseISO8601Date(createdAt)
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: - 线程列表响应

/// 线程列表 API 响应
///
/// 对应 `GET /v1/threads` 返回格式
public struct ThreadsListResponse: Codable, Sendable {
    /// 线程数据数组
    public let data: [Thread]

    /// 分页游标（用于获取下一页）
    public let nextCursor: String?

    public init(data: [Thread], nextCursor: String?) {
        self.data = data
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case items
        case nextCursor
        case next_cursor
    }

    public init(from decoder: Decoder) throws {
        // 兼容直接返回数组的场景
        if let singleValue = try? decoder.singleValueContainer(),
           let threads = try? singleValue.decode([Thread].self)
        {
            self.data = threads
            self.nextCursor = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.data) {
            self.data = try container.decode([Thread].self, forKey: .data)
        } else if container.contains(.items) {
            self.data = try container.decode([Thread].self, forKey: .items)
        } else {
            self.data = []
        }

        let nextCursorString =
            (try? container.decodeIfPresent(String.self, forKey: .nextCursor))
            ?? (try? container.decodeIfPresent(String.self, forKey: .next_cursor))
        let nextCursorInt =
            (try? container.decodeIfPresent(Int.self, forKey: .nextCursor))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .next_cursor))
        self.nextCursor = nextCursorString ?? nextCursorInt.map(String.init)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
    }
}

// MARK: - 创建线程请求

/// 创建线程请求体
///
/// 对应 `POST /v1/threads` 请求格式
public struct CreateThreadRequest: Codable, Sendable {
    /// 项目 ID（与 projectPath 二选一）
    public var projectId: String?

    /// 项目路径（与 projectId 二选一）
    public var projectPath: String?

    /// 线程名称（可选）
    public var threadName: String?

    /// 审批策略（默认 on-request）
    public var approvalPolicy: String?

    /// 沙箱模式（默认 workspace-write）
    public var sandbox: String?

    /// 模型 ID（可选，留空表示使用后端默认）
    public var model: String?

    public init(
        projectId: String? = nil,
        projectPath: String? = nil,
        threadName: String? = nil,
        approvalPolicy: String? = nil,
        sandbox: String? = nil,
        model: String? = nil
    ) {
        self.projectId = projectId
        self.projectPath = projectPath
        self.threadName = threadName
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.model = model
    }
}

// MARK: - 项目模型

/// 项目信息
///
/// 对应 `GET /v1/projects` 返回的项目对象
public struct Project: Identifiable, Codable, Equatable, Sendable {
    /// 项目唯一标识符
    public let projectId: String

    /// 项目路径
    public let projectPath: String

    /// 显示名称
    public let displayName: String

    // MARK: - Identifiable

    public var id: String { projectId }

    public init(projectId: String, projectPath: String, displayName: String) {
        self.projectId = projectId
        self.projectPath = projectPath
        self.displayName = displayName
    }
}

/// 项目列表响应
public struct ProjectsListResponse: Codable, Sendable {
    public let data: [Project]
}
