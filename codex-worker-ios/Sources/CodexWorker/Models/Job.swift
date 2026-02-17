//
//  Job.swift
//  CodexWorker
//
//  任务模型 - 与后端 API 对齐
//

import Foundation

// MARK: - 任务状态

/// 任务状态枚举（与后端状态机对齐）
///
/// 状态机：
/// ```
/// QUEUED -> RUNNING -> WAITING_APPROVAL -> RUNNING -> DONE/FAILED/CANCELLED
/// ```
public enum JobState: String, Codable, Equatable, Sendable {
    /// 排队中
    case queued = "QUEUED"
    /// 运行中
    case running = "RUNNING"
    /// 等待审批
    case waitingApproval = "WAITING_APPROVAL"
    /// 已完成
    case done = "DONE"
    /// 失败
    case failed = "FAILED"
    /// 已取消
    case cancelled = "CANCELLED"

    /// 是否为终态（不会再变化）
    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// 是否为活跃状态（正在执行）
    public var isActive: Bool {
        switch self {
        case .queued, .running, .waitingApproval:
            return true
        default:
            return false
        }
    }
}

// MARK: - 任务模型

/// 任务快照
///
/// 对应后端 `GET /v1/jobs/{jobId}` 返回的任务对象
///
/// 示例 JSON:
/// ```json
/// {
///   "jobId": "job_xyz789",
///   "threadId": "thread_abc123",
///   "turnId": "turn_def456",
///   "state": "RUNNING",
///   "pendingApprovalCount": 0,
///   "createdAt": "2026-02-15T10:30:00.000Z",
///   "updatedAt": "2026-02-15T10:30:05.000Z",
///   "terminalAt": null,
///   "errorMessage": null
/// }
/// ```
public struct Job: Identifiable, Codable, Equatable, Sendable {
    /// 任务唯一标识符
    public let jobId: String

    /// 所属线程 ID
    public let threadId: String

    /// Turn ID（对话轮次标识）
    public var turnId: String?

    /// 当前状态
    public var state: JobState

    /// 待处理审批数量
    public var pendingApprovalCount: Int

    /// 创建时间（ISO 8601 格式）
    public let createdAt: String

    /// 更新时间（ISO 8601 格式）
    public var updatedAt: String

    /// 终态时间（进入终态的时间）
    public var terminalAt: String?

    /// 错误消息（失败时）
    public var errorMessage: String?

    // MARK: - Identifiable

    public var id: String { jobId }

    public init(
        jobId: String,
        threadId: String,
        turnId: String?,
        state: JobState,
        pendingApprovalCount: Int,
        createdAt: String,
        updatedAt: String,
        terminalAt: String?,
        errorMessage: String?
    ) {
        self.jobId = jobId
        self.threadId = threadId
        self.turnId = turnId
        self.state = state
        self.pendingApprovalCount = pendingApprovalCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.terminalAt = terminalAt
        self.errorMessage = errorMessage
    }
}

// MARK: - 计算属性

extension Job {
    /// 创建时间 Date
    public var createdDate: Date? {
        ISO8601DateFormatter().date(from: createdAt)
    }

    /// 更新时间 Date
    public var updatedDate: Date? {
        ISO8601DateFormatter().date(from: updatedAt)
    }

    /// 终态时间 Date
    public var terminalDate: Date? {
        guard let terminalAt = terminalAt else { return nil }
        return ISO8601DateFormatter().date(from: terminalAt)
    }

    /// 是否有错误
    public var hasError: Bool {
        errorMessage != nil && !errorMessage!.isEmpty
    }
}

// MARK: - Turn 请求

/// 发送消息（创建 Turn）请求体
///
/// 对应 `POST /v1/threads/{threadId}/turns` 请求格式
public struct StartTurnRequest: Codable, Sendable {
    /// 文本消息（与 input 二选一）
    public var text: String?

    /// 结构化输入数组（与 text 二选一）
    public var input: [TurnInput]?

    /// 覆盖审批策略（可选）
    public var approvalPolicy: String?

    /// 覆盖沙箱模式（可选）
    public var sandbox: String?

    public init(
        text: String?,
        input: [TurnInput]?,
        approvalPolicy: String?,
        sandbox: String? = nil
    ) {
        self.text = text
        self.input = input
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
    }
}

/// Turn 输入项
public struct TurnInput: Codable, Sendable {
    /// 输入类型（通常为 "text"）
    public let type: String

    /// 文本内容
    public let text: String

    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

// MARK: - Turn 响应

/// 发送消息响应
///
/// 对应 `POST /v1/threads/{threadId}/turns` 返回
public struct StartTurnResponse: Codable, Sendable {
    /// 任务 ID
    public let jobId: String

    /// 任务状态
    public let state: String

    /// 线程 ID
    public let threadId: String?

    /// Turn ID
    public let turnId: String?
}
