//
//  Thread.swift
//  CodexWorker
//
//  线程模型 - 与后端 API 对齐
//

import Foundation

// MARK: - 线程状态

/// 线程状态枚举
enum ThreadState: String, Codable, Sendable {
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
struct Thread: Identifiable, Codable, Equatable, Sendable {
    /// 线程唯一标识符
    let threadId: String

    /// 最近消息预览文本
    var preview: String?

    /// 当前工作目录（Current Working Directory）
    var cwd: String?

    /// 创建时间（ISO 8601 格式）
    var createdAt: String?

    /// 更新时间（ISO 8601 格式）
    var updatedAt: String?

    /// 模型提供者（如 openai、anthropic）
    var modelProvider: String?

    // MARK: - Identifiable

    var id: String { threadId }
}

// MARK: - 计算属性

extension Thread {
    /// 显示名称（从 cwd 提取最后一段）
    var displayName: String {
        guard let cwd = cwd else { return "Untitled" }
        let components = cwd.split(separator: "/")
        return components.last.map(String.init) ?? "Untitled"
    }

    /// 最后活跃时间（解析 ISO 8601 时间戳）
    var lastActiveAt: Date? {
        guard let updatedAt = updatedAt else { return nil }
        return ISO8601DateFormatter().date(from: updatedAt)
    }

    /// 创建时间 Date
    var createdDate: Date? {
        guard let createdAt = createdAt else { return nil }
        return ISO8601DateFormatter().date(from: createdAt)
    }
}

// MARK: - 线程列表响应

/// 线程列表 API 响应
///
/// 对应 `GET /v1/threads` 返回格式
struct ThreadsListResponse: Codable, Sendable {
    /// 线程数据数组
    let data: [Thread]

    /// 分页游标（用于获取下一页）
    let nextCursor: String?
}

// MARK: - 创建线程请求

/// 创建线程请求体
///
/// 对应 `POST /v1/threads` 请求格式
struct CreateThreadRequest: Codable, Sendable {
    /// 项目 ID（与 projectPath 二选一）
    var projectId: String?

    /// 项目路径（与 projectId 二选一）
    var projectPath: String?

    /// 线程名称（可选）
    var threadName: String?

    /// 审批策略（默认 on-request）
    var approvalPolicy: String?

    /// 沙箱模式（默认 workspace-write）
    var sandbox: String?
}

// MARK: - 项目模型

/// 项目信息
///
/// 对应 `GET /v1/projects` 返回的项目对象
struct Project: Identifiable, Codable, Equatable, Sendable {
    /// 项目唯一标识符
    let projectId: String

    /// 项目路径
    let projectPath: String

    /// 显示名称
    let displayName: String

    // MARK: - Identifiable

    var id: String { projectId }
}

/// 项目列表响应
struct ProjectsListResponse: Codable, Sendable {
    let data: [Project]
}
