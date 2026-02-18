//
//  ThreadHistoryStore.swift
//  CodexWorker
//
//  线程历史本地缓存（GRDB + SQLite）
//

import ComposableArchitecture
import Foundation
import GRDB

/// 线程历史缓存依赖
///
/// 目标：
/// - 本地秒开（先读缓存）
/// - 远端增量同步（按线程游标 cursor）
public struct ThreadHistoryStore: DependencyKey, Sendable {
    /// 读取线程缓存事件（按线程游标升序）
    public var loadCachedEvents: @Sendable (_ threadId: String) async throws -> [EventEnvelope]
    /// 读取线程同步游标
    public var loadCursor: @Sendable (_ threadId: String) async throws -> Int
    /// 合并远端分页到本地缓存
    public var mergeRemotePage: @Sendable (
        _ threadId: String,
        _ requestCursor: Int,
        _ page: ThreadEventsResponse
    ) async throws -> Void
    /// 追加实时流式事件到本地缓存（用于崩溃恢复/离线回看）
    public var appendLiveEvent: @Sendable (
        _ threadId: String,
        _ event: EventEnvelope
    ) async throws -> Void
    /// 清空线程缓存（游标过期时用于重建）
    public var resetThread: @Sendable (_ threadId: String) async throws -> Void

    public static var liveValue: ThreadHistoryStore {
        let store: LiveThreadHistoryStore?
        do {
            store = try LiveThreadHistoryStore.makeDefault()
        } catch {
            store = nil
        }

        return ThreadHistoryStore(
            loadCachedEvents: { threadId in
                guard let store else { return [] }
                return try await store.loadCachedEvents(threadId: threadId)
            },
            loadCursor: { threadId in
                guard let store else { return -1 }
                return try await store.loadCursor(threadId: threadId)
            },
            mergeRemotePage: { threadId, requestCursor, page in
                guard let store else { return }
                try await store.mergeRemotePage(
                    threadId: threadId,
                    requestCursor: requestCursor,
                    page: page
                )
            },
            appendLiveEvent: { threadId, event in
                guard let store else { return }
                try await store.appendLiveEvent(threadId: threadId, event: event)
            },
            resetThread: { threadId in
                guard let store else { return }
                try await store.resetThread(threadId: threadId)
            }
        )
    }

    public static let testValue = ThreadHistoryStore.noop
    public static let previewValue = ThreadHistoryStore.noop

    private static let noop = ThreadHistoryStore(
        loadCachedEvents: { _ in [] },
        loadCursor: { _ in -1 },
        mergeRemotePage: { _, _, _ in },
        appendLiveEvent: { _, _ in },
        resetThread: { _ in }
    )
}

extension DependencyValues {
    public var threadHistoryStore: ThreadHistoryStore {
        get { self[ThreadHistoryStore.self] }
        set { self[ThreadHistoryStore.self] = newValue }
    }
}

actor LiveThreadHistoryStore {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    static func makeDefault() throws -> LiveThreadHistoryStore {
        let dbURL = try defaultDatabaseURL()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try migrate(dbQueue: dbQueue)
        return LiveThreadHistoryStore(dbQueue: dbQueue)
    }

    func loadCachedEvents(threadId: String) throws -> [EventEnvelope] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT jobId, seq, type, ts, payloadJson
                FROM thread_events
                WHERE threadId = ?
                ORDER BY threadCursor ASC
                """,
                arguments: [threadId]
            )
            return try rows.map { row in
                let payloadJson: String? = row["payloadJson"]
                return EventEnvelope(
                    type: row["type"],
                    ts: row["ts"],
                    jobId: row["jobId"],
                    seq: row["seq"],
                    payload: try decodePayload(payloadJson)
                )
            }
        }
    }

    func loadCursor(threadId: String) throws -> Int {
        try dbQueue.read { db in
            if let cursor = try Int.fetchOne(
                db,
                sql: "SELECT nextCursor FROM thread_sync_state WHERE threadId = ?",
                arguments: [threadId]
            ) {
                return cursor
            }
            return (try Int.fetchOne(
                db,
                sql: "SELECT MAX(threadCursor) FROM thread_events WHERE threadId = ?",
                arguments: [threadId]
            )) ?? -1
        }
    }

    func mergeRemotePage(
        threadId: String,
        requestCursor: Int,
        page: ThreadEventsResponse
    ) throws {
        try dbQueue.write { db in
            var threadCursor = requestCursor
            for event in page.data {
                threadCursor += 1
                _ = try upsertEvent(
                    db: db,
                    threadId: threadId,
                    threadCursor: threadCursor,
                    event: event
                )
            }

            let existingCursor = (try Int.fetchOne(
                db,
                sql: "SELECT nextCursor FROM thread_sync_state WHERE threadId = ?",
                arguments: [threadId]
            )) ?? -1
            let mergedCursor = max(existingCursor, requestCursor, page.nextCursor, threadCursor)
            try db.execute(
                sql: """
                INSERT INTO thread_sync_state(threadId, nextCursor, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(threadId) DO UPDATE SET
                    nextCursor = excluded.nextCursor,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [threadId, mergedCursor, ISO8601DateFormatter().string(from: Date())]
            )
        }
    }

    func appendLiveEvent(threadId: String, event: EventEnvelope) throws {
        try dbQueue.write { db in
            // 同一线程内，优先以 (jobId, seq) 去重。
            // 兼容旧版本库里可能存在的 UNIQUE(threadId, jobId, seq) 约束，避免 SQLite 19。
            if let existingCursor = try Int.fetchOne(
                db,
                sql: """
                SELECT threadCursor
                FROM thread_events
                WHERE threadId = ? AND jobId = ? AND seq = ?
                LIMIT 1
                """,
                arguments: [threadId, event.jobId, event.seq]
            ) {
                try db.execute(
                    sql: """
                    UPDATE thread_events
                    SET type = ?, ts = ?, payloadJson = ?
                    WHERE threadId = ? AND threadCursor = ?
                    """,
                    arguments: [
                        event.type,
                        event.ts,
                        try encodePayload(event.payload),
                        threadId,
                        existingCursor,
                    ]
                )
                try upsertCursor(db: db, threadId: threadId, cursor: existingCursor)
                return
            }

            let maxCursor = (try Int.fetchOne(
                db,
                sql: "SELECT MAX(threadCursor) FROM thread_events WHERE threadId = ?",
                arguments: [threadId]
            )) ?? -1
            let nextCursor = maxCursor + 1

            let appliedCursor = try upsertEvent(
                db: db,
                threadId: threadId,
                threadCursor: nextCursor,
                event: event
            )
            try upsertCursor(db: db, threadId: threadId, cursor: appliedCursor)
        }
    }

    func resetThread(threadId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM thread_events WHERE threadId = ?",
                arguments: [threadId]
            )
            try db.execute(
                sql: "DELETE FROM thread_sync_state WHERE threadId = ?",
                arguments: [threadId]
            )
        }
    }

    private func encodePayload(_ payload: [String: JSONValue]?) throws -> String? {
        guard let payload else { return nil }
        let data = try encoder.encode(payload)
        return String(data: data, encoding: .utf8)
    }

    private func decodePayload(_ payloadJson: String?) throws -> [String: JSONValue]? {
        guard let payloadJson, !payloadJson.isEmpty else { return nil }
        guard let data = payloadJson.data(using: .utf8) else { return nil }
        return try decoder.decode([String: JSONValue].self, from: data)
    }

    private func upsertCursor(db: Database, threadId: String, cursor: Int) throws {
        let existingCursor = (try Int.fetchOne(
            db,
            sql: "SELECT nextCursor FROM thread_sync_state WHERE threadId = ?",
            arguments: [threadId]
        )) ?? -1
        let mergedCursor = max(existingCursor, cursor)
        try db.execute(
            sql: """
            INSERT INTO thread_sync_state(threadId, nextCursor, updatedAt)
            VALUES (?, ?, ?)
            ON CONFLICT(threadId) DO UPDATE SET
                nextCursor = excluded.nextCursor,
                updatedAt = excluded.updatedAt
            """,
            arguments: [threadId, mergedCursor, ISO8601DateFormatter().string(from: Date())]
        )
    }

    /// 按事件键与线程游标双重策略写入：
    /// 1. 先按 (threadId, jobId, seq) 查重并更新，兼容旧 UNIQUE 约束。
    /// 2. 再按 (threadId, threadCursor) 覆盖或插入。
    private func upsertEvent(
        db: Database,
        threadId: String,
        threadCursor: Int,
        event: EventEnvelope
    ) throws -> Int {
        let payloadJson = try encodePayload(event.payload)

        if let existingCursor = try Int.fetchOne(
            db,
            sql: """
            SELECT threadCursor
            FROM thread_events
            WHERE threadId = ? AND jobId = ? AND seq = ?
            LIMIT 1
            """,
            arguments: [threadId, event.jobId, event.seq]
        ) {
            try db.execute(
                sql: """
                UPDATE thread_events
                SET type = ?, ts = ?, payloadJson = ?
                WHERE threadId = ? AND threadCursor = ?
                """,
                arguments: [event.type, event.ts, payloadJson, threadId, existingCursor]
            )
            return existingCursor
        }

        if let cursorExists = try Int.fetchOne(
            db,
            sql: """
            SELECT 1
            FROM thread_events
            WHERE threadId = ? AND threadCursor = ?
            LIMIT 1
            """,
            arguments: [threadId, threadCursor]
        ), cursorExists == 1 {
            try db.execute(
                sql: """
                UPDATE thread_events
                SET jobId = ?, seq = ?, type = ?, ts = ?, payloadJson = ?
                WHERE threadId = ? AND threadCursor = ?
                """,
                arguments: [
                    event.jobId,
                    event.seq,
                    event.type,
                    event.ts,
                    payloadJson,
                    threadId,
                    threadCursor,
                ]
            )
            return threadCursor
        }

        try db.execute(
            sql: """
            INSERT INTO thread_events(
                threadId, threadCursor, jobId, seq, type, ts, payloadJson
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                threadId,
                threadCursor,
                event.jobId,
                event.seq,
                event.type,
                event.ts,
                payloadJson,
            ]
        )
        return threadCursor
    }
}

private extension LiveThreadHistoryStore {
    static func migrate(dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create_thread_history_cache_v1") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS thread_events (
                    threadId TEXT NOT NULL,
                    threadCursor INTEGER NOT NULL,
                    jobId TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    ts TEXT NOT NULL,
                    payloadJson TEXT,
                    PRIMARY KEY (threadId, threadCursor)
                );

                CREATE INDEX IF NOT EXISTS idx_thread_events_lookup
                ON thread_events(threadId, threadCursor);

                CREATE TABLE IF NOT EXISTS thread_sync_state (
                    threadId TEXT PRIMARY KEY,
                    nextCursor INTEGER NOT NULL,
                    updatedAt TEXT NOT NULL
                );
                """
            )
        }
        migrator.registerMigration("add_thread_events_unique_event_key_v2") { db in
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_thread_events_unique_event_key
                ON thread_events(threadId, jobId, seq, type);
                """
            )
        }
        try migrator.migrate(dbQueue)
    }

    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("CodexWorker", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("thread-history.sqlite")
    }
}
