//
//  Terminal.swift
//  CodexWorker
//
//  远端终端模型
//

import Foundation

// MARK: - 终端会话快照

public struct TerminalSessionSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    public var threadId: String
    public var cwd: String
    public var shell: String
    public var pid: Int
    public var status: String
    public var createdAt: String?
    public var lastActiveAt: String?
    public var cols: Int
    public var rows: Int
    public var exitCode: Int?
    public var signal: String?
    public var nextSeq: Int
    public var clientCount: Int?

    public init(
        sessionId: String,
        threadId: String,
        cwd: String,
        shell: String,
        pid: Int,
        status: String,
        createdAt: String?,
        lastActiveAt: String?,
        cols: Int,
        rows: Int,
        exitCode: Int?,
        signal: String?,
        nextSeq: Int,
        clientCount: Int?
    ) {
        self.sessionId = sessionId
        self.threadId = threadId
        self.cwd = cwd
        self.shell = shell
        self.pid = pid
        self.status = status
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.cols = cols
        self.rows = rows
        self.exitCode = exitCode
        self.signal = signal
        self.nextSeq = nextSeq
        self.clientCount = clientCount
    }
}

// MARK: - REST 响应

public struct ThreadTerminalStatusResponse: Codable, Equatable, Sendable {
    public let session: TerminalSessionSnapshot?
}

public struct ThreadTerminalOpenResponse: Codable, Equatable, Sendable {
    public let session: TerminalSessionSnapshot
    public let reused: Bool
    public let wsPath: String?
}

public struct TerminalResizeResponse: Codable, Equatable, Sendable {
    public let session: TerminalSessionSnapshot
}

public struct TerminalCloseResponse: Codable, Equatable, Sendable {
    public let session: TerminalSessionSnapshot
}

public struct ThreadTerminalOpenRequest: Codable, Equatable, Sendable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalCloseRequest: Codable, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct TerminalResizeRequest: Codable, Equatable, Sendable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

// MARK: - WebSocket 帧

public struct TerminalStreamFrame: Codable, Equatable, Sendable {
    public let type: String
    public let seq: Int?
    public let data: String?
    public let exitCode: Int?
    public let signal: String?
    public let sessionId: String?
    public let threadId: String?
    public let cwd: String?
    public let code: String?
    public let message: String?
    public let clientTs: String?
}

public struct TerminalClientMessage: Codable, Equatable, Sendable {
    public let type: String
    public let data: String?
    public let cols: Int?
    public let rows: Int?
    public let clientTs: String?

    public static func input(_ data: String) -> TerminalClientMessage {
        TerminalClientMessage(type: "input", data: data, cols: nil, rows: nil, clientTs: nil)
    }

    public static func resize(cols: Int, rows: Int) -> TerminalClientMessage {
        TerminalClientMessage(type: "resize", data: nil, cols: cols, rows: rows, clientTs: nil)
    }

    public static func ping(clientTs: String) -> TerminalClientMessage {
        TerminalClientMessage(type: "ping", data: nil, cols: nil, rows: nil, clientTs: clientTs)
    }

    public static let detach = TerminalClientMessage(type: "detach", data: nil, cols: nil, rows: nil, clientTs: nil)
}
