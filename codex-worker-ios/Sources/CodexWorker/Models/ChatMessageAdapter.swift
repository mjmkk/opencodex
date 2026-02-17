//
//  ChatMessageAdapter.swift
//  CodexWorker
//
//  聊天消息适配器 - 将 Codex 消息适配到 exyte/Chat
//

import Foundation
import ExyteChat

// MARK: - 消息发送者

/// 消息发送者类型
public enum MessageSender: Sendable {
    /// 当前用户（iPhone 用户）
    case user
    /// AI 助手
    case assistant
    /// 系统消息
    case system
}

// MARK: - 预定义用户

/// 预定义用户集合
public enum ChatUsers {
    /// 当前用户（iPhone 用户）
    static let currentUser = User(
        id: "user",
        name: "You",
        avatarURL: nil,
        isCurrentUser: true
    )

    /// AI 助手
    static let assistantUser = User(
        id: "assistant",
        name: "Codex",
        avatarURL: nil,
        isCurrentUser: false
    )

    /// 系统用户
    static let systemUser = User(
        id: "system",
        name: "System",
        avatarURL: nil,
        isCurrentUser: false
    )

    /// 根据发送者类型获取用户
    static func user(for sender: MessageSender) -> User {
        switch sender {
        case .user:
            return currentUser
        case .assistant:
            return assistantUser
        case .system:
            return systemUser
        }
    }
}

// MARK: - ChatMessage 适配器

/// 将 Codex 消息适配到 exyte/Chat 的 Message
public enum ChatMessageAdapter {
    /// 从事件数据构建消息
    ///
    /// - Parameters:
    ///   - itemId: 消息 ID（通常是 item ID）
    ///   - sender: 发送者类型
    ///   - text: 消息文本
    ///   - createdAt: 创建时间
    /// - Returns: exyte/Chat 的 Message 对象
    static func makeMessage(
        id: String,
        sender: MessageSender,
        text: String,
        status: Message.Status = .sent,
        createdAt: Date = Date()
    ) -> Message {
        let user = ChatUsers.user(for: sender)

        return Message(
            id: id,
            user: user,
            status: status,
            createdAt: createdAt,
            text: text,
            attachments: [],
            giphyMediaId: nil,
            reactions: [],
            recording: nil,
            replyMessage: nil
        )
    }

    /// 从事件信封构建消息
    ///
    /// - Parameters:
    ///   - envelope: SSE 事件信封
    ///   - isComplete: 消息是否已完成
    /// - Returns: Message 对象（如果解析成功）
    static func fromEvent(
        envelope: EventEnvelope,
        isComplete: Bool = false
    ) -> Message? {
        guard let payload = envelope.payload else { return nil }

        let itemId = payload["itemId"]?.stringValue ?? envelope.jobId
        let text = payload["delta"]?.stringValue ?? ""
        let createdAt = envelope.timestamp ?? Date()

        return makeMessage(
            id: itemId,
            sender: .assistant,
            text: text,
            createdAt: createdAt
        )
    }
}

// MARK: - 消息增量状态

/// 消息增量状态（用于 delta 合并）
///
/// 用于处理 `item.agentMessage.delta` 事件的增量文本合并
public struct MessageDelta: Identifiable, Equatable, Sendable {
    /// 消息 ID（itemId）
    public let id: String

    /// 累积的文本内容
    var text: String

    /// 是否已完成（收到 item.completed）
    var isComplete: Bool

    /// 发送者类型
    let sender: MessageSender

    /// 创建时间
    let createdAt: Date

    /// 更新时间
    var updatedAt: Date

    // MARK: - 初始化

    init(
        id: String,
        text: String = "",
        isComplete: Bool = false,
        sender: MessageSender = .assistant,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.isComplete = isComplete
        self.sender = sender
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - 操作

    /// 追加增量文本
    mutating func append(_ delta: String) {
        text += delta
        updatedAt = Date()
    }

    /// 标记为完成
    mutating func markComplete() {
        isComplete = true
        updatedAt = Date()
    }

    /// 转换为最终消息
    func toMessage() -> Message {
        ChatMessageAdapter.makeMessage(
            id: id,
            sender: sender,
            text: text,
            createdAt: createdAt
        )
    }
}

// MARK: - 消息聚合器

/// 消息聚合器
///
/// 管理消息和增量的合并，用于 ChatFeature
actor MessageAggregator {
    /// 已完成的消息列表
    private(set) var messages: [String: Message] = [:]

    /// 进行中的增量消息
    private(set) var pendingDeltas: [String: MessageDelta] = [:]

    /// 消息顺序（用于保持顺序）
    private(set) var messageOrder: [String] = []

    // MARK: - 添加消息

    /// 添加新消息
    func addMessage(_ message: Message) {
        if messages[message.id] == nil {
            messageOrder.append(message.id)
        }
        messages[message.id] = message
    }

    /// 添加或更新增量
    func addDelta(itemId: String, delta: String, sender: MessageSender = .assistant) {
        if var existing = pendingDeltas[itemId] {
            existing.append(delta)
            pendingDeltas[itemId] = existing
            // 同步更新 messages
            messages[itemId] = existing.toMessage()
        } else {
            let newDelta = MessageDelta(
                id: itemId,
                text: delta,
                sender: sender
            )
            pendingDeltas[itemId] = newDelta
            messageOrder.append(itemId)
            messages[itemId] = newDelta.toMessage()
        }
    }

    /// 标记消息完成
    func completeMessage(itemId: String) {
        if var delta = pendingDeltas[itemId] {
            delta.markComplete()
            pendingDeltas.removeValue(forKey: itemId)
            messages[itemId] = delta.toMessage()
        }
    }

    // MARK: - 获取消息

    /// 获取有序消息列表
    func getOrderedMessages() -> [Message] {
        messageOrder.compactMap { messages[$0] }
    }

    /// 获取特定消息
    func getMessage(id: String) -> Message? {
        messages[id]
    }

    /// 获取进行中的增量
    func getPendingDelta(itemId: String) -> MessageDelta? {
        pendingDeltas[itemId]
    }

    // MARK: - 清理

    /// 清空所有消息
    func clear() {
        messages.removeAll()
        pendingDeltas.removeAll()
        messageOrder.removeAll()
    }
}

// MARK: - 非并发版本（用于 TCA State）

/// 消息聚合状态（非 actor 版本，用于 TCA State）
public struct MessageAggregationState: Equatable, Sendable {
    /// 已完成的消息列表
    var messages: [String: Message] = [:]

    /// 进行中的增量消息
    var pendingDeltas: [String: MessageDelta] = [:]

    /// 消息顺序
    var messageOrder: [String] = []

    // MARK: - 操作

    /// 添加或更新增量
    mutating func addDelta(itemId: String, delta: String, sender: MessageSender = .assistant) {
        if var existing = pendingDeltas[itemId] {
            existing.append(delta)
            pendingDeltas[itemId] = existing
            messages[itemId] = existing.toMessage()
        } else {
            let newDelta = MessageDelta(
                id: itemId,
                text: delta,
                sender: sender
            )
            pendingDeltas[itemId] = newDelta
            messageOrder.append(itemId)
            messages[itemId] = newDelta.toMessage()
        }
    }

    /// 标记消息完成
    mutating func completeMessage(itemId: String) {
        if var delta = pendingDeltas[itemId] {
            delta.markComplete()
            pendingDeltas.removeValue(forKey: itemId)
            messages[itemId] = delta.toMessage()
        }
    }

    /// 添加完整消息
    mutating func addMessage(_ message: Message) {
        if messages[message.id] == nil {
            messageOrder.append(message.id)
        }
        messages[message.id] = message
    }

    /// 获取有序消息列表
    func getOrderedMessages() -> [Message] {
        messageOrder.compactMap { messages[$0] }
    }

    /// 清空
    mutating func clear() {
        messages.removeAll()
        pendingDeltas.removeAll()
        messageOrder.removeAll()
    }
}
