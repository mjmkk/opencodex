//
//  FileSystemStore.swift
//  CodexWorker
//
//  文件浏览本地缓存（GRDB + SQLite）
//

import ComposableArchitecture
import Foundation
import GRDB

public struct CachedFileRevision: Equatable, Sendable {
    public let path: String
    public let etag: String
    public let content: String
    public let fetchedAtMs: Int64

    public init(path: String, etag: String, content: String, fetchedAtMs: Int64) {
        self.path = path
        self.etag = etag
        self.content = content
        self.fetchedAtMs = fetchedAtMs
    }
}

public struct FileSystemStore: DependencyKey, Sendable {
    public var loadTreeCache: @Sendable (_ rootPath: String, _ path: String) async throws -> FileTreeResponse?
    public var saveTreeCache: @Sendable (_ rootPath: String, _ path: String, _ response: FileTreeResponse) async throws -> Void

    public var loadFileChunkCache: @Sendable (
        _ rootPath: String,
        _ path: String,
        _ etag: String,
        _ fromLine: Int,
        _ toLine: Int
    ) async throws -> FileContentPayload?
    public var loadLatestFileChunkCache: @Sendable (
        _ rootPath: String,
        _ path: String
    ) async throws -> FileContentPayload?
    public var saveFileChunkCache: @Sendable (
        _ rootPath: String,
        _ payload: FileContentPayload
    ) async throws -> Void

    public var saveRevision: @Sendable (_ path: String, _ etag: String, _ content: String) async throws -> Void
    public var listRevisions: @Sendable (_ path: String, _ limit: Int) async throws -> [CachedFileRevision]

    public static var liveValue: FileSystemStore {
        let store: LiveFileSystemStore?
        do {
            store = try LiveFileSystemStore.makeDefault()
        } catch {
            store = nil
        }

        return FileSystemStore(
            loadTreeCache: { rootPath, path in
                guard let store else { return nil }
                return try await store.loadTreeCache(rootPath: rootPath, path: path)
            },
            saveTreeCache: { rootPath, path, response in
                guard let store else { return }
                try await store.saveTreeCache(rootPath: rootPath, path: path, response: response)
            },
            loadFileChunkCache: { rootPath, path, etag, fromLine, toLine in
                guard let store else { return nil }
                return try await store.loadFileChunkCache(
                    rootPath: rootPath,
                    path: path,
                    etag: etag,
                    fromLine: fromLine,
                    toLine: toLine
                )
            },
            loadLatestFileChunkCache: { rootPath, path in
                guard let store else { return nil }
                return try await store.loadLatestFileChunkCache(rootPath: rootPath, path: path)
            },
            saveFileChunkCache: { rootPath, payload in
                guard let store else { return }
                try await store.saveFileChunkCache(rootPath: rootPath, payload: payload)
            },
            saveRevision: { path, etag, content in
                guard let store else { return }
                try await store.saveRevision(path: path, etag: etag, content: content)
            },
            listRevisions: { path, limit in
                guard let store else { return [] }
                return try await store.listRevisions(path: path, limit: limit)
            }
        )
    }

    public static let testValue = FileSystemStore.noop
    public static let previewValue = FileSystemStore.noop

    private static let noop = FileSystemStore(
        loadTreeCache: { _, _ in nil },
        saveTreeCache: { _, _, _ in },
        loadFileChunkCache: { _, _, _, _, _ in nil },
        loadLatestFileChunkCache: { _, _ in nil },
        saveFileChunkCache: { _, _ in },
        saveRevision: { _, _, _ in },
        listRevisions: { _, _ in [] }
    )
}

extension DependencyValues {
    public var fileSystemStore: FileSystemStore {
        get { self[FileSystemStore.self] }
        set { self[FileSystemStore.self] = newValue }
    }
}

actor LiveFileSystemStore {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    static func makeDefault() throws -> LiveFileSystemStore {
        let dbURL = try defaultDatabaseURL()
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try migrate(dbQueue: dbQueue)
        return LiveFileSystemStore(dbQueue: dbQueue)
    }

    func loadTreeCache(rootPath: String, path: String) throws -> FileTreeResponse? {
        // 用只读事务执行 SELECT，避免不必要的写锁争用。
        let result: FileTreeResponse? = try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT payloadJson
                FROM fs_dir_cache
                WHERE rootPath = ? AND path = ?
                LIMIT 1
                """,
                arguments: [rootPath, path]
            )
            guard let row,
                  let payloadJson: String = row["payloadJson"],
                  let payloadData = payloadJson.data(using: .utf8)
            else {
                return nil
            }
            return try decoder.decode(FileTreeResponse.self, from: payloadData)
        }
        // 仅命中缓存时才异步更新访问时间（LRU），不需要与读操作原子化。
        if result != nil {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE fs_dir_cache
                    SET accessedAtMs = ?
                    WHERE rootPath = ? AND path = ?
                    """,
                    arguments: [Self.nowMs(), rootPath, path]
                )
            }
        }
        return result
    }

    func saveTreeCache(rootPath: String, path: String, response: FileTreeResponse) throws {
        let payloadData = try encoder.encode(response)
        let payloadJson = String(decoding: payloadData, as: UTF8.self)
        let nowMs = Self.nowMs()

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO fs_dir_cache(rootPath, path, etag, payloadJson, fetchedAtMs, accessedAtMs)
                VALUES (?, ?, NULL, ?, ?, ?)
                ON CONFLICT(rootPath, path) DO UPDATE SET
                    payloadJson = excluded.payloadJson,
                    fetchedAtMs = excluded.fetchedAtMs,
                    accessedAtMs = excluded.accessedAtMs
                """,
                arguments: [rootPath, path, payloadJson, nowMs, nowMs]
            )
            try trimDirectoryCacheIfNeeded(db: db)
        }
    }

    func loadFileChunkCache(
        rootPath: String,
        path: String,
        etag: String,
        fromLine: Int,
        toLine: Int
    ) throws -> FileContentPayload? {
        try dbQueue.write { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT payloadJson
                FROM fs_file_chunk_cache
                WHERE rootPath = ? AND path = ? AND etag = ? AND fromLine = ? AND toLine = ?
                LIMIT 1
                """,
                arguments: [rootPath, path, etag, fromLine, toLine]
            )
            guard let row,
                  let payloadJson: String = row["payloadJson"],
                  let payloadData = payloadJson.data(using: .utf8)
            else {
                return nil
            }

            try db.execute(
                sql: """
                UPDATE fs_file_chunk_cache
                SET accessedAtMs = ?
                WHERE rootPath = ? AND path = ? AND etag = ? AND fromLine = ? AND toLine = ?
                """,
                arguments: [Self.nowMs(), rootPath, path, etag, fromLine, toLine]
            )

            return try decoder.decode(FileContentPayload.self, from: payloadData)
        }
    }

    func saveFileChunkCache(rootPath: String, payload: FileContentPayload) throws {
        let payloadData = try encoder.encode(payload)
        let payloadJson = String(decoding: payloadData, as: UTF8.self)
        let nowMs = Self.nowMs()

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO fs_file_chunk_cache(
                    rootPath, path, etag, fromLine, toLine, payloadJson, fetchedAtMs, accessedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(rootPath, path, etag, fromLine, toLine) DO UPDATE SET
                    payloadJson = excluded.payloadJson,
                    fetchedAtMs = excluded.fetchedAtMs,
                    accessedAtMs = excluded.accessedAtMs
                """,
                arguments: [
                    rootPath,
                    payload.path,
                    payload.etag,
                    payload.fromLine,
                    payload.toLine,
                    payloadJson,
                    nowMs,
                    nowMs,
                ]
            )
            try trimFileChunkCacheIfNeeded(db: db)
        }
    }

    func loadLatestFileChunkCache(rootPath: String, path: String) throws -> FileContentPayload? {
        // 用只读事务执行 SELECT，避免不必要的写锁争用。
        struct RowSnapshot { var etag: String; var fromLine: Int; var toLine: Int; var payload: FileContentPayload }
        let snapshot: RowSnapshot? = try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT etag, fromLine, toLine, payloadJson
                FROM fs_file_chunk_cache
                WHERE rootPath = ? AND path = ?
                ORDER BY fetchedAtMs DESC
                LIMIT 1
                """,
                arguments: [rootPath, path]
            )
            guard let row,
                  let payloadJson: String = row["payloadJson"],
                  let payloadData = payloadJson.data(using: .utf8)
            else {
                return nil
            }
            let payload = try decoder.decode(FileContentPayload.self, from: payloadData)
            return RowSnapshot(etag: row["etag"], fromLine: row["fromLine"], toLine: row["toLine"], payload: payload)
        }
        guard let snapshot else { return nil }
        // 仅命中缓存时才异步更新访问时间（LRU），不需要与读操作原子化。
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE fs_file_chunk_cache
                SET accessedAtMs = ?
                WHERE rootPath = ? AND path = ? AND etag = ? AND fromLine = ? AND toLine = ?
                """,
                arguments: [
                    Self.nowMs(),
                    rootPath,
                    path,
                    snapshot.etag,
                    snapshot.fromLine,
                    snapshot.toLine,
                ]
            )
        }
        return snapshot.payload
    }

    func saveRevision(path: String, etag: String, content: String) throws {
        try dbQueue.write { db in
            // 同一 etag 已存在时跳过插入，避免重复打开同一文件产生重复修订记录。
            try db.execute(
                sql: """
                INSERT INTO fs_file_revision_cache(path, etag, content, fetchedAtMs)
                SELECT ?, ?, ?, ?
                WHERE NOT EXISTS (
                    SELECT 1 FROM fs_file_revision_cache WHERE path = ? AND etag = ?
                )
                """,
                arguments: [path, etag, content, Self.nowMs(), path, etag]
            )
            try trimRevisionsIfNeeded(db: db, path: path)
        }
    }

    func listRevisions(path: String, limit: Int) throws -> [CachedFileRevision] {
        let normalizedLimit = max(1, min(limit, 30))
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT path, etag, content, fetchedAtMs
                FROM fs_file_revision_cache
                WHERE path = ?
                ORDER BY fetchedAtMs DESC
                LIMIT ?
                """,
                arguments: [path, normalizedLimit]
            )
            return rows.map { row in
                CachedFileRevision(
                    path: row["path"],
                    etag: row["etag"],
                    content: row["content"],
                    fetchedAtMs: row["fetchedAtMs"]
                )
            }
        }
    }

    private func trimDirectoryCacheIfNeeded(db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fs_dir_cache") ?? 0
        guard count > 500 else { return }
        let overflow = count - 500
        try db.execute(
            sql: """
            DELETE FROM fs_dir_cache
            WHERE rowid IN (
                SELECT rowid
                FROM fs_dir_cache
                ORDER BY accessedAtMs ASC
                LIMIT ?
            )
            """,
            arguments: [overflow]
        )
    }

    private func trimFileChunkCacheIfNeeded(db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fs_file_chunk_cache") ?? 0
        guard count > 2000 else { return }
        let overflow = count - 2000
        try db.execute(
            sql: """
            DELETE FROM fs_file_chunk_cache
            WHERE rowid IN (
                SELECT rowid
                FROM fs_file_chunk_cache
                ORDER BY accessedAtMs ASC
                LIMIT ?
            )
            """,
            arguments: [overflow]
        )
    }

    private func trimRevisionsIfNeeded(db: Database, path: String) throws {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM fs_file_revision_cache WHERE path = ?",
            arguments: [path]
        ) ?? 0
        guard count > 20 else { return }
        let overflow = count - 20
        try db.execute(
            sql: """
            DELETE FROM fs_file_revision_cache
            WHERE rowid IN (
                SELECT rowid
                FROM fs_file_revision_cache
                WHERE path = ?
                ORDER BY fetchedAtMs ASC
                LIMIT ?
            )
            """,
            arguments: [path, overflow]
        )
    }
}

private extension LiveFileSystemStore {
    static func migrate(dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("create_file_system_cache_v1") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS fs_dir_cache (
                    rootPath TEXT NOT NULL,
                    path TEXT NOT NULL,
                    etag TEXT,
                    payloadJson TEXT NOT NULL,
                    fetchedAtMs INTEGER NOT NULL,
                    accessedAtMs INTEGER NOT NULL,
                    PRIMARY KEY (rootPath, path)
                );

                CREATE TABLE IF NOT EXISTS fs_file_chunk_cache (
                    rootPath TEXT NOT NULL,
                    path TEXT NOT NULL,
                    etag TEXT NOT NULL,
                    fromLine INTEGER NOT NULL,
                    toLine INTEGER NOT NULL,
                    payloadJson TEXT NOT NULL,
                    fetchedAtMs INTEGER NOT NULL,
                    accessedAtMs INTEGER NOT NULL,
                    PRIMARY KEY (rootPath, path, etag, fromLine, toLine)
                );

                CREATE INDEX IF NOT EXISTS idx_fs_file_chunk_cache_lru
                ON fs_file_chunk_cache(accessedAtMs);

                CREATE TABLE IF NOT EXISTS fs_file_revision_cache (
                    path TEXT NOT NULL,
                    etag TEXT NOT NULL,
                    content TEXT NOT NULL,
                    fetchedAtMs INTEGER NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_fs_file_revision_cache_path
                ON fs_file_revision_cache(path, fetchedAtMs DESC);
                """
            )
        }

        try migrator.migrate(dbQueue)
    }

    static func defaultDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("CodexWorker", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("thread-history.sqlite")
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
