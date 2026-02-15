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
enum JobState: String, Codable, Equatable, Sendable {
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
    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// 是否为活跃状态（正在执行）
    var isActive: Bool {
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
struct Job: Identifiable, Codable, Equatable, Sendable {
    /// 任务唯一标识符
    let jobId: String

    /// 所属线程 ID
    let threadId: String

    /// Turn ID（对话轮次标识）
    var turnId: String?

    /// 当前状态
    var state: JobState

    /// 待处理审批数量
    var pendingApprovalCount: Int

    /// 创建时间（ISO 8601 格式）
    let createdAt: String

    /// 更新时间（ISO 8601 格式）
    var updatedAt: String

    /// 终态时间（进入终态的时间）
    var terminalAt: String?

    /// 错误消息（失败时）
    var errorMessage: String?

    // MARK: - Identifiable

    var id: String { jobId }
}

// MARK: - 计算属性

extension Job {
    /// 创建时间 Date
    var createdDate: Date? {
        ISO8601DateFormatter().date(from: createdAt)
    }

    /// 更新时间 Date
    var updatedDate: Date? {
        ISO8601DateFormatter().date(from: updatedAt)
    }

    /// 终态时间 Date
    var terminalDate: Date? {
        guard let terminalAt = terminalAt else { return nil }
        return ISO8601DateFormatter().date(from: terminalAt)
    }

    /// 是否有错误
    var hasError: Bool {
        errorMessage != nil && !errorMessage!.isEmpty
    }
}

// MARK: - Turn 请求

/// 发送消息（创建 Turn）请求体
///
/// 对应 `POST /v1/threads/{threadId}/turns` 请求格式
struct StartTurnRequest: Codable, Sendable {
    /// 文本消息（与 input 二选一）
    var text: String?

    /// 结构化输入数组（与 text 二选一）
    var input: [TurnInput]?

    /// 覆盖审批策略（可选）
    var approvalPolicy: String?
}

/// Turn 输入项
struct TurnInput: Codable, Sendable {
    /// 输入类型（通常为 "text"）
    let type: String

    /// 文本内容
    let text: String
}

// MARK: - Turn 响应

/// 发送消息响应
///
/// 对应 `POST /v1/threads/{threadId}/turns` 返回
struct StartTurnResponse: Codable, Sendable {
    /// 任务 ID
    let jobId: String

    /// 任务状态
    let state: String

    /// 线程 ID
    let threadId: String?

    /// Turn ID
    let turnId: String?
}
