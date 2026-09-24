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
        name: "你",
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
        name: "系统",
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

}
