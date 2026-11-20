//
//  Thread.swift
//  CodexWorker
//
//  线程模型 - 与后端 API 对齐
//

import Foundation

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
    public var name: String?
    public var nativeManaged = false
    public var executionState: String? = nil
    var origin: ThreadOrigin? = nil
    public var sourceDevice: String? { origin?.hostID }
    public var hasCachedSource: Bool { origin != nil }
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
    public var pendingRequestCount: Int

    // MARK: - Identifiable

    public var id: String { (origin?.namespace ?? "legacy") + ":" + threadId }

    public init(
        threadId: String,
        preview: String?,
        cwd: String?,
        createdAt: String?,
        updatedAt: String?,
        modelProvider: String?,
        pendingRequestCount: Int = 0
    ) {
        self.threadId = threadId
        self.preview = preview
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelProvider = modelProvider
        self.pendingRequestCount = max(0, pendingRequestCount)
    }

    private enum CodingKeys: String, CodingKey {
        case nativeManaged, executionState, name, origin
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
        case pendingRequestCount
        case pending_request_count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nativeManaged = try container.decodeIfPresent(Bool.self, forKey: .nativeManaged) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name)
        origin = try container.decodeIfPresent(ThreadOrigin.self, forKey: .origin)
        executionState = try container.decodeIfPresent(String.self, forKey: .executionState)

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
        self.pendingRequestCount = max(
            0,
            Self.decodeLossyInt(from: container, keys: [.pendingRequestCount, .pending_request_count]) ?? 0
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
        try container.encode(pendingRequestCount, forKey: .pendingRequestCount)
        try container.encode(nativeManaged, forKey: .nativeManaged)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(executionState, forKey: .executionState)
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
        if let name, !name.isEmpty { return name }
        if let first = preview?.split(whereSeparator: \.isNewline).first, !first.isEmpty { return String(first) }
        return "未命名任务"
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
        // Sorting and accessibility read these properties repeatedly. The value-type
        // strategy reuses Foundation's parser instead of constructing ICU formatters
        // for every comparison, which can stall a large real directory on the main thread.
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")).parse(value)
    }
}

struct ThreadOrigin: Codable, Equatable, Sendable { var namespace: String; var hostID: String? }
