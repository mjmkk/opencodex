import Foundation
import GRDB

public struct SyncCheckpoint: Equatable, Sendable {
    public var cursor: Int
    public var generation: String?
    public var replacingGeneration: String?
    public init(cursor: Int = -1, generation: String? = nil, replacingGeneration: String? = nil) {
        self.cursor = cursor; self.generation = generation; self.replacingGeneration = replacingGeneration
    }
}

public struct ThreadSyncMetadata: Equatable, Sendable {
    public var lastSyncedAt: Date?
    public var unreadEvents: Int
    public var pinned: Bool
    public var latestCursor: Int = -1
    public var generation: String? = nil
    public var isRebuilding: Bool = false
}

/// Uses the existing GRDB history database. A new generation is staged without
/// removing the last readable generation; only its final page becomes visible.
actor MobileSyncCache {
    static let shared: MobileSyncCache? = try? MobileSyncCache()
    private let db: DatabaseQueue

    init(path: String? = nil) throws {
        var resolvedPath = path
        if resolvedPath == nil {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CodexWorker", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resolvedPath = directory.appendingPathComponent("thread-history.sqlite").path
        }
        db = try DatabaseQueue(path: resolvedPath!)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mobile_approvals (
                  scope TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,id));
                CREATE TABLE IF NOT EXISTS mobile_approval_drafts (
                  scope TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,id));
                CREATE TABLE IF NOT EXISTS mobile_threads (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, value BLOB NOT NULL,
                  readCursor INTEGER NOT NULL DEFAULT -1, pinned INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(scope, threadId));
                CREATE TABLE IF NOT EXISTS mobile_sync (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL,
                  generation TEXT, visibleCursor INTEGER NOT NULL DEFAULT -1, syncedAt REAL,
                  pendingGeneration TEXT, pendingCursor INTEGER NOT NULL DEFAULT -1,
                  PRIMARY KEY(scope, threadId));
                CREATE TABLE IF NOT EXISTS mobile_events (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, generation TEXT NOT NULL,
                  cursor INTEGER NOT NULL, value BLOB NOT NULL,
                  PRIMARY KEY(scope, threadId, generation, cursor));
                CREATE TABLE IF NOT EXISTS mobile_provisional (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, jobId TEXT NOT NULL,
                  seq INTEGER NOT NULL, value BLOB NOT NULL,
                  PRIMARY KEY(scope, threadId, jobId, seq));
                CREATE TABLE IF NOT EXISTS mobile_job_watermarks (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, jobId TEXT NOT NULL, seq INTEGER NOT NULL,
                  PRIMARY KEY(scope, threadId, jobId));
                """)
        }
    }

    func approvals(scope: String) throws -> ([MobileApproval], [String: MobileApprovalDraft]) {
        try db.read { db in
            let documents = try Data.fetchAll(db, sql: "SELECT value FROM mobile_approvals WHERE scope=? ORDER BY rowid DESC", arguments: [scope])
                .map { try JSONDecoder().decode(MobileApproval.self, from: $0) }
            let rows = try Row.fetchAll(db, sql: "SELECT id,value FROM mobile_approval_drafts WHERE scope=?", arguments: [scope])
            let drafts = try Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["id"] as String, try JSONDecoder().decode(MobileApprovalDraft.self, from: row["value"]))
            })
            return (documents, drafts)
        }
    }
    func saveApprovals(_ documents: [MobileApproval], scope: String) throws {
        try db.write { db in
            for document in documents {
                try db.execute(sql: "INSERT INTO mobile_approvals(scope,id,value) VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value",
                    arguments: [scope, document.id, try JSONEncoder().encode(document)])
            }
        }
    }
    func saveApprovalDraft(_ draft: MobileApprovalDraft, id: String, scope: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO mobile_approval_drafts(scope,id,value) VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value",
                arguments: [scope, id, try JSONEncoder().encode(draft)])
        }
    }

    func threads(scope: String) throws -> [Thread] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT value FROM mobile_threads WHERE scope=?", arguments: [scope])
                .map { try JSONDecoder().decode(Thread.self, from: $0) }
        }
    }

    func saveThreads(_ threads: [Thread], scope: String) throws {
        try db.write { db in
            for thread in threads {
                try db.execute(sql: """
                    INSERT INTO mobile_threads(scope,threadId,value) VALUES(?,?,?)
                    ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value
                    """, arguments: [scope, thread.threadId, try JSONEncoder().encode(thread)])
            }
        }
    }

    func checkpoint(_ threadId: String, scope: String) throws -> SyncCheckpoint {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mobile_sync WHERE scope=? AND threadId=?",
                arguments: [scope, threadId]) else { return SyncCheckpoint() }
            let pending: String? = row["pendingGeneration"]
            return SyncCheckpoint(cursor: pending == nil ? row["visibleCursor"] : row["pendingCursor"],
                generation: pending ?? row["generation"])
        }
    }

    func events(_ threadId: String, scope: String) throws -> [EventEnvelope] {
        try db.read { db in
            let committed = try Data.fetchAll(db, sql: """
                SELECT e.value FROM mobile_events e JOIN mobile_sync s
                ON e.scope=s.scope AND e.threadId=s.threadId AND e.generation=s.generation
                WHERE e.scope=? AND e.threadId=? AND e.cursor<=s.visibleCursor ORDER BY e.cursor
                """, arguments: [scope, threadId])
                .map { try JSONDecoder().decode(EventEnvelope.self, from: $0) }
            let provisional = try Data.fetchAll(db, sql: """
                SELECT value FROM mobile_provisional WHERE scope=? AND threadId=? ORDER BY rowid
                """, arguments: [scope, threadId]).map { try JSONDecoder().decode(EventEnvelope.self, from: $0) }
            return committed + provisional
        }
    }

    func appendProvisional(_ events: [EventEnvelope], threadId: String, scope: String) throws {
        try db.write { db in
            for event in events where event.seq >= 0 {
                let synced = try Int.fetchOne(db, sql: "SELECT seq FROM mobile_job_watermarks WHERE scope=? AND threadId=? AND jobId=?", arguments: [scope, threadId, event.jobId]) ?? -1
                if event.seq <= synced { continue }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO mobile_provisional(scope,threadId,jobId,seq,value) VALUES(?,?,?,?,?)
                    """, arguments: [scope, threadId, event.jobId, event.seq, try JSONEncoder().encode(event)])
            }
        }
    }

    func merge(_ page: ThreadEventsResponse, after checkpoint: SyncCheckpoint,
               threadId: String, scope: String) throws {
        guard let generation = page.generation, !generation.isEmpty,
              checkpoint.generation == nil || checkpoint.generation == generation else {
            throw CodexError.cursorExpired
        }
        var cursor = checkpoint.cursor
        for event in page.data {
            guard event.threadCursor == cursor + 1 else { throw CodexError.invalidState }
            cursor += 1
        }
        guard page.nextCursor == cursor, !page.hasMore || !page.data.isEmpty else {
            throw CodexError.invalidState
        }
        try db.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM mobile_sync WHERE scope=? AND threadId=?", arguments: [scope, threadId])
            let activeGeneration: String? = row?["pendingGeneration"] ?? row?["generation"]
            let currentCursor: Int = (row?["pendingGeneration"] as String?) == nil ? (row?["visibleCursor"] ?? -1) : (row?["pendingCursor"] ?? -1)
            if activeGeneration == generation && currentCursor >= page.nextCursor && currentCursor > checkpoint.cursor {
                // An identical completed page can be delivered twice; it cannot move progress back.
                for event in page.data {
                    guard let data = try Data.fetchOne(db, sql: "SELECT value FROM mobile_events WHERE scope=? AND threadId=? AND generation=? AND cursor=?",
                        arguments: [scope, threadId, generation, event.threadCursor]),
                        try JSONDecoder().decode(EventEnvelope.self, from: data) == event else { throw CodexError.invalidState }
                }
                return
            }
            let continuing = activeGeneration == checkpoint.generation && currentCursor == checkpoint.cursor
            let rebuilding = checkpoint.cursor == -1 && checkpoint.generation == nil &&
                activeGeneration == checkpoint.replacingGeneration
            guard continuing || rebuilding else { throw CodexError.invalidState }
            for event in page.data {
                try db.execute(sql: """
                    INSERT INTO mobile_events(scope,threadId,generation,cursor,value) VALUES(?,?,?,?,?)
                    """, arguments: [scope, threadId, generation, event.threadCursor, try JSONEncoder().encode(event)])
            }
            try db.execute(sql: """
                INSERT INTO mobile_sync(scope,threadId,pendingGeneration,pendingCursor) VALUES(?,?,?,?)
                ON CONFLICT(scope,threadId) DO UPDATE SET
                  pendingGeneration=excluded.pendingGeneration,pendingCursor=excluded.pendingCursor
                """, arguments: [scope, threadId, generation, page.nextCursor])
            if !page.hasMore {
                let previousGeneration: String? = row?["generation"]
                try db.execute(sql: """
                    UPDATE mobile_sync SET generation=?,visibleCursor=?,syncedAt=COALESCE(?,syncedAt),
                      pendingGeneration=NULL,pendingCursor=-1 WHERE scope=? AND threadId=?
                    """, arguments: [generation, page.nextCursor, page.sourceConnected == false ? nil : Date().timeIntervalSince1970, scope, threadId])
                try db.execute(sql: "DELETE FROM mobile_events WHERE scope=? AND threadId=? AND generation<>?",
                    arguments: [scope, threadId, generation])
                if previousGeneration != nil && previousGeneration != generation {
                    try db.execute(sql: "UPDATE mobile_threads SET readCursor=-1 WHERE scope=? AND threadId=?", arguments: [scope, threadId])
                    try db.execute(sql: "DELETE FROM mobile_provisional WHERE scope=? AND threadId=?", arguments: [scope, threadId])
                    try db.execute(sql: "DELETE FROM mobile_job_watermarks WHERE scope=? AND threadId=?", arguments: [scope, threadId])
                } else {
                    let committed = try Data.fetchAll(db, sql: "SELECT value FROM mobile_events WHERE scope=? AND threadId=? AND generation=?",
                        arguments: [scope, threadId, generation]).map { try JSONDecoder().decode(EventEnvelope.self, from: $0) }
                    var last: [String: Int] = [:]
                    for event in committed where event.seq >= 0 { last[event.jobId] = max(last[event.jobId] ?? -1, event.seq) }
                    for (job, seq) in last {
                        try db.execute(sql: """
                            INSERT INTO mobile_job_watermarks(scope,threadId,jobId,seq) VALUES(?,?,?,?)
                            ON CONFLICT(scope,threadId,jobId) DO UPDATE SET seq=MAX(seq,excluded.seq)
                            """, arguments: [scope, threadId, job, seq])
                        try db.execute(sql: "DELETE FROM mobile_provisional WHERE scope=? AND threadId=? AND jobId=? AND seq<=?", arguments: [scope, threadId, job, seq])
                    }
                }
            }
        }
    }

    func metadata(scope: String) throws -> [String: ThreadSyncMetadata] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.threadId,t.pinned,t.readCursor,s.visibleCursor,s.syncedAt,s.generation,s.pendingGeneration FROM mobile_threads t
                LEFT JOIN mobile_sync s ON t.scope=s.scope AND t.threadId=s.threadId WHERE t.scope=?
                """, arguments: [scope])
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let synced: Double? = row["syncedAt"]
                let visible: Int? = row["visibleCursor"]
                let read: Int = row["readCursor"]
                return (row["threadId"], ThreadSyncMetadata(lastSyncedAt: synced.map(Date.init(timeIntervalSince1970:)),
                    unreadEvents: max(0, (visible ?? -1) - read), pinned: row["pinned"], latestCursor: visible ?? -1,
                    generation: row["generation"], isRebuilding: (row["pendingGeneration"] as String?) != nil))
            })
        }
    }

    func markRead(_ threadId: String, scope: String) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE mobile_threads SET readCursor=COALESCE((SELECT visibleCursor FROM mobile_sync
                  WHERE scope=? AND threadId=?),-1) WHERE scope=? AND threadId=?
                """, arguments: [scope, threadId, scope, threadId])
        }
    }

    func setPinned(_ pinned: Bool, threadId: String, scope: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE mobile_threads SET pinned=? WHERE scope=? AND threadId=?",
                arguments: [pinned, scope, threadId])
        }
    }
}
