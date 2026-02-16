//
//  Event.swift
//  CodexWorker
//
//  SSE 事件模型 - 与后端 API 对齐
//

import Foundation

// MARK: - 事件类型枚举

/// SSE 事件类型
///
/// 对应后端事件信封中的 `type` 字段
public enum EventType: String, CaseIterable, Sendable {
    // MARK: - 生命周期事件

    /// 任务创建
    case jobCreated = "job.created"
    /// 任务状态变更
    case jobState = "job.state"
    /// 任务完成（终态）
    case jobFinished = "job.finished"
    /// 轮次开始
    case turnStarted = "turn.started"
    /// 轮次完成
    case turnCompleted = "turn.completed"

    // MARK: - 消息事件

    /// 项目开始（如 agentMessage 开始）
    case itemStarted = "item.started"
    /// 项目完成
    case itemCompleted = "item.completed"
    /// AI 消息增量（流式文本）
    case itemAgentMessageDelta = "item.agentMessage.delta"
    /// 命令执行输出增量
    case itemCommandExecutionOutputDelta = "item.commandExecution.outputDelta"
    /// 文件变更输出增量
    case itemFileChangeOutputDelta = "item.fileChange.outputDelta"

    // MARK: - 审批事件

    /// 审批请求
    case approvalRequired = "approval.required"
    /// 审批已处理
    case approvalResolved = "approval.resolved"

    // MARK: - 其他事件

    /// 错误
    case error = "error"
    /// 线程启动
    case threadStarted = "thread.started"

    // MARK: - 分类

    /// 是否为消息相关事件
    public var isMessageEvent: Bool {
        switch self {
        case .itemStarted, .itemCompleted, .itemAgentMessageDelta,
             .itemCommandExecutionOutputDelta, .itemFileChangeOutputDelta:
            return true
        default:
            return false
        }
    }

    /// 是否为审批相关事件
    public var isApprovalEvent: Bool {
        self == .approvalRequired || self == .approvalResolved
    }
}

// MARK: - SSE 事件信封

/// SSE 事件信封（与后端对齐）
///
/// 后端返回格式：
/// ```
/// id: <seq>
/// event: <type>
/// data: <json>
///
/// ```
///
/// JSON 结构：
/// ```json
/// {
///   "type": "item.agentMessage.delta",
///   "ts": "2026-02-15T10:30:00.000Z",
///   "jobId": "job_xyz789",
///   "seq": 42,
///   "payload": { ... }
/// }
/// ```
public struct EventEnvelope: Codable, Equatable, Sendable {
    /// 事件类型
    public let type: String

    /// 时间戳（ISO 8601 格式）
    public let ts: String

    /// 任务 ID
    public let jobId: String

    /// 序列号（严格递增）
    public let seq: Int

    /// 事件负载数据
    public let payload: [String: JSONValue]?

    public init(type: String, ts: String, jobId: String, seq: Int, payload: [String: JSONValue]?) {
        self.type = type
        self.ts = ts
        self.jobId = jobId
        self.seq = seq
        self.payload = payload
    }
}

// MARK: - 事件信封扩展

extension EventEnvelope {
    /// 解析事件类型枚举
    public var eventType: EventType? {
        EventType(rawValue: type)
    }

    /// 解析时间 Date
    public var timestamp: Date? {
        ISO8601DateFormatter().date(from: ts)
    }

    /// 从 payload 提取字符串
    public func payloadString(_ key: String) -> String? {
        payload?[key]?.stringValue
    }

    /// 从 payload 提取整数
    public func payloadInt(_ key: String) -> Int? {
        payload?[key]?.intValue
    }

    /// 从 payload 提取布尔值
    public func payloadBool(_ key: String) -> Bool? {
        payload?[key]?.boolValue
    }
}

// MARK: - JSON 值类型

/// JSON 值类型（用于解析动态 payload）
///
/// 支持解析后端返回的动态 JSON 结构
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // 尝试按优先级解码
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    // MARK: - 值提取

    /// 提取字符串值
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// 提取整数值
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// 提取浮点数值
    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }

    /// 提取布尔值
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// 提取对象
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// 提取数组
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

// MARK: - 事件列表响应

/// 事件列表 API 响应
///
/// 对应 `GET /v1/jobs/{jobId}/events?cursor=N` 返回
public struct EventsListResponse: Codable, Sendable {
    /// 事件数据数组
    public let data: [EventEnvelope]

    /// 下一个游标
    public let nextCursor: Int

    /// 第一个序列号
    public let firstSeq: Int?

    /// 任务快照（可选）
    public let job: Job?
}

// MARK: - 线程历史事件响应

/// 线程历史事件响应
///
/// 对应 `GET /v1/threads/{threadId}/events` 返回
public struct ThreadEventsResponse: Codable, Sendable {
    public let data: [EventEnvelope]
}
