import Foundation
import GRDB

public struct ThreadSyncMetadata: Equatable, Sendable {
    public var lastSyncedAt: Date?
    public var unreadMessages: Int
    public var pinned: Bool
    public var isPartial: Bool = false
}

/// Persists readable Thread history and local drafts. No execution or approval lifecycle.
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
                CREATE TABLE IF NOT EXISTS mobile_mirror_bodies (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,threadId));
                CREATE TABLE IF NOT EXISTS mobile_mirror_staging (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,threadId));
                CREATE TABLE IF NOT EXISTS mobile_native_observations (
                  scope TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,id));
                CREATE TABLE IF NOT EXISTS mobile_native_drafts (
                  scope TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,id));
                CREATE TABLE IF NOT EXISTS mobile_composer_drafts (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,threadId));
                CREATE TABLE IF NOT EXISTS mobile_threads (
                  scope TEXT NOT NULL, threadId TEXT NOT NULL, value BLOB NOT NULL,
                  readCursor INTEGER NOT NULL DEFAULT -1, pinned INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(scope, threadId));
                CREATE TABLE IF NOT EXISTS mobile_selection (scope TEXT PRIMARY KEY, threadId TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS mobile_observer_snapshots (
                  scope TEXT NOT NULL, name TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,name));
                """)
        }
    }

    /// Rebuildable observer responses share the existing account-scoped cache.
    func goalOverview(scope: String) throws -> GoalOverviewCacheEntry? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM mobile_observer_snapshots WHERE scope=? AND name='goal-overview'", arguments: [scope])
                .map { try JSONDecoder().decode(GoalOverviewCacheEntry.self, from: $0) }
        }
    }

    func saveGoalOverview(_ entry: GoalOverviewCacheEntry, scope: String) throws {
        _ = try GoalOverviewDecoder.inventoryValidation(entry.payload)
        try db.write { db in
            guard let incoming = entry.payload.objectValue,
                  let namespace = incoming["namespace"]?.stringValue,
                  let revision = incoming["snapshot_revision"]?.intValue else { throw CodexError.invalidState }
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM mobile_observer_snapshots WHERE scope=? AND name='goal-overview'", arguments: [scope]),
               let saved = try? JSONDecoder().decode(GoalOverviewCacheEntry.self, from: data),
               let previous = saved.payload.objectValue,
               previous["namespace"]?.stringValue == namespace,
               let oldRevision = previous["snapshot_revision"]?.intValue,
               oldRevision > revision { throw CodexError.invalidState }
            try db.execute(sql: "INSERT INTO mobile_observer_snapshots(scope,name,value) VALUES(?,'goal-overview',?) ON CONFLICT(scope,name) DO UPDATE SET value=excluded.value",
                arguments: [scope, try JSONEncoder().encode(entry)])
        }
    }

    func composer(threadId: String, scope: String) throws -> ComposerDraft? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM mobile_composer_drafts WHERE scope=? AND threadId=?", arguments: [scope,threadId])
                .map { try JSONDecoder().decode(ComposerDraft.self, from: $0) }
        }
    }
    func saveComposer(_ draft: ComposerDraft, threadId: String, scope: String) throws {
        try db.write { db in
            var draft = draft
            draft.controlAttempt = nil
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM mobile_composer_drafts WHERE scope=? AND threadId=?", arguments: [scope,threadId]) {
                let previous = try JSONDecoder().decode(ComposerDraft.self, from: data)
                guard (draft.editedAt ?? .distantPast) >= (previous.editedAt ?? .distantPast) else { return }
                guard draft.editedAt != previous.editedAt || draft.textRevision == previous.textRevision else { return }
                guard draft.textRevision != previous.textRevision || draft.text == previous.text else { return }
                // Delayed ordinary draft saves cannot clear or downgrade a sealed
                // control attempt. Only the dedicated methods below change it.
                draft.controlAttempt = previous.controlAttempt
                // An accepted input consumed this exact editing revision. A
                // delayed save of it must not restore the submitted body. A
                // genuinely newer edit has its own revision and remains valid.
                if previous.controlAttempt?.operation == .input,
                   previous.controlAttempt?.receipt?.status == "accepted",
                   let consumed = previous.controlAttempt?.draftTextRevision,
                   draft.textRevision == consumed {
                    draft.text = previous.text; draft.textRevision = previous.textRevision
                    draft.editedAt = previous.editedAt
                }
            }
            try db.execute(sql: "INSERT INTO mobile_composer_drafts(scope,threadId,value) VALUES(?,?,?) ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value",
                arguments: [scope,threadId,try JSONEncoder().encode(draft)])
        }
    }

    func beginControlAttempt(_ attempt: NativeControlAttempt, text: String,
                             textRevision: String? = nil, editedAt: Date? = nil,
                             threadId: String, scope: String) throws -> ComposerDraft {
        try db.write { db in
            var draft = try Data.fetchOne(db, sql: "SELECT value FROM mobile_composer_drafts WHERE scope=? AND threadId=?", arguments: [scope,threadId])
                .map { try JSONDecoder().decode(ComposerDraft.self, from: $0) } ?? ComposerDraft(editedAt: nil)
            guard draft.controlAttempt?.isUncertain != true,
                  attempt.operation != .input || draft.outgoing == nil || draft.outgoing?.acknowledgedReceiptID != nil else { throw CodexError.invalidState }
            let revision = textRevision ?? (draft.text == text ? draft.textRevision : nil) ?? UUID().uuidString
            let editTime = editedAt ?? (draft.text == text ? draft.editedAt : nil) ?? attempt.attemptedAt
            var sealed = attempt; sealed.draftTextRevision = revision
            let sameRevision = draft.textRevision == revision
            let bindsLegacyRevision = draft.textRevision == nil && draft.text == text && draft.editedAt == editedAt
            if bindsLegacyRevision || (sameRevision ? text == draft.text && editTime >= (draft.editedAt ?? .distantPast)
                : editTime > (draft.editedAt ?? .distantPast)) {
                draft.text = text; draft.textRevision = revision; draft.editedAt = editTime
            }
            draft.controlAttempt = sealed
            try db.execute(sql: "INSERT INTO mobile_composer_drafts(scope,threadId,value) VALUES(?,?,?) ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value",
                arguments: [scope,threadId,try JSONEncoder().encode(draft)])
            return draft
        }
    }

    func reconcileControlAttempt(id: String, receipt: NativeControlReceipt? = nil, localRejection: String? = nil,
                                 threadId: String, scope: String) throws -> ComposerDraft {
        try db.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM mobile_composer_drafts WHERE scope=? AND threadId=?", arguments: [scope,threadId]) else { throw CodexError.invalidState }
            var draft = try JSONDecoder().decode(ComposerDraft.self, from: data)
            guard let previous = draft.controlAttempt, previous.request.submission_id == id else { return draft }
            let attempt = try previous.reconciled(receipt: receipt, localRejection: localRejection, threadID: threadId)
            if attempt.operation == .input, attempt.receipt?.status == "accepted", draft.text == attempt.request.text,
               let revision = attempt.draftTextRevision, draft.textRevision == revision {
                draft.text = ""; draft.textRevision = UUID().uuidString
            }
            // Receipt metadata is not a user edit. Advancing editedAt here
            // would discard a newer edit whose ordinary save is still queued.
            draft.controlAttempt = attempt
            try db.execute(sql: "UPDATE mobile_composer_drafts SET value=? WHERE scope=? AND threadId=?",
                arguments: [try JSONEncoder().encode(draft),scope,threadId])
            return draft
        }
    }

    func nativeRequests(scope: String) throws -> [NativeRequestRecord] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT value FROM mobile_native_observations WHERE scope=?", arguments: [scope])
                .map { try JSONDecoder().decode(NativeRequestRecord.self, from: $0) }
                .sorted { $0.observedAt > $1.observedAt }
        }
    }

    func saveNativeRequest(_ item: NativeRemoteRequest, scope: String) throws {
        let record = NativeRequestRecord(item: item, observedAt: Date())
        try db.write { db in
            try db.execute(sql: "INSERT INTO mobile_native_observations(scope,id,value) VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value",
                arguments: [scope, item.id, try JSONEncoder().encode(record)])
        }
    }

    func nativeDraft(id: String, scope: String) throws -> NativeRequestDraft? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM mobile_native_drafts WHERE scope=? AND id=?", arguments: [scope,id])
                .map { try JSONDecoder().decode(NativeRequestDraft.self, from: $0) }
        }
    }

    func saveNativeDraft(_ draft: NativeRequestDraft, id: String, scope: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO mobile_native_drafts(scope,id,value) VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value",
                arguments: [scope,id,try JSONEncoder().encode(draft)])
        }
    }

    func mirrorBody(_ id: String, scope: String) throws -> MirrorCachedBody? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM mobile_mirror_bodies WHERE scope=? AND threadId=?", arguments: [scope,id])
                .map { try JSONDecoder().decode(MirrorCachedBody.self, from: $0) }
        }
    }

    func saveMirrorIndex(_ index: MirrorIndex, scope: String) throws {
        var threads = index.threads.map { $0.thread(in: index.namespace) }
        for i in threads.indices {
            if let body = try mirrorBody(threads[i].threadId, scope: scope)?.body {
                threads[i].preview = body.messages.last(where: { $0.role == "assistant" && $0.text_content?.isEmpty == false })?.text_content
            }
        }
        try saveThreads(threads, scope: scope)
    }

    func saveMirrorBody(_ body: MirrorBody, scope: String) throws {
        let value = MirrorCachedBody(body: body, downloadedAt: Date())
        var thread = body.thread.thread(in: body.namespace)
        thread.preview = body.messages.last(where: { $0.role == "assistant" && $0.text_content?.isEmpty == false })?.text_content
        try db.write { db in
            try db.execute(sql: "INSERT INTO mobile_mirror_bodies(scope,threadId,value) VALUES(?,?,?) ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value",
                arguments: [scope,thread.threadId,try JSONEncoder().encode(value)])
            try Self.saveHistoryPreview(thread, scope: scope, in: db)
        }
    }

    private static func saveHistoryPreview(_ fallback: Thread, scope: String, in db: Database) throws {
        // A readable snapshot may predate the current task catalog. Preserve saved
        // task fields (including nil); only an absent task uses history metadata.
        var thread = try Data.fetchOne(db,
            sql: "SELECT value FROM mobile_threads WHERE scope=? AND threadId=?",
            arguments: [scope, fallback.threadId])
            .map { try JSONDecoder().decode(Thread.self, from: $0) } ?? fallback
        thread.preview = fallback.preview
        try db.execute(sql: "INSERT INTO mobile_threads(scope,threadId,value) VALUES(?,?,?) ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value",
            arguments: [scope, thread.threadId, try JSONEncoder().encode(thread)])
    }

    func mirrorStaging(_ id: String, scope: String) throws -> MirrorBody? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM mobile_mirror_staging WHERE scope=? AND threadId=?", arguments: [scope,id])
                .map { try JSONDecoder().decode(MirrorBody.self, from: $0) }
        }
    }

    func discardMirrorStaging(_ id: String, scope: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM mobile_mirror_staging WHERE scope=? AND threadId=?", arguments: [scope,id])
        }
    }

    /// Checkpoint partial downloads separately; publish a replacement only when complete.
    func saveMirrorProgress(_ body: MirrorBody, scope: String) throws {
        let id = body.thread.thread_id
        let value = MirrorCachedBody(body: body, downloadedAt: Date())
        var thread = body.thread.thread(in: body.namespace)
        thread.preview = body.messages.last(where: { $0.role == "assistant" && $0.text_content?.isEmpty == false })?.text_content
        try db.write { db in
            let old = try Data.fetchOne(db, sql: "SELECT value FROM mobile_mirror_bodies WHERE scope=? AND threadId=?", arguments: [scope,id])
                .map { try JSONDecoder().decode(MirrorCachedBody.self, from: $0) }
            let staged = try Data.fetchOne(db, sql: "SELECT value FROM mobile_mirror_staging WHERE scope=? AND threadId=?", arguments: [scope,id])
                .map { try JSONDecoder().decode(MirrorBody.self, from: $0) }
            // Foreground and background reads may finish out of order. A shorter
            // checkpoint of the same immutable snapshot must not erase readable work.
            let incomingOffset = body.page.next_offset ?? Int.max
            if [old?.body, staged].compactMap({ $0 }).contains(where: {
                $0.page.snapshot == body.page.snapshot && ($0.page.next_offset ?? Int.max) > incomingOffset
            }) { return }
            if body.page.next_offset != nil {
                try db.execute(sql: "INSERT INTO mobile_mirror_staging(scope,threadId,value) VALUES(?,?,?) ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value",
                    arguments: [scope,id,try JSONEncoder().encode(body)])
            } else {
                try db.execute(sql: "DELETE FROM mobile_mirror_staging WHERE scope=? AND threadId=?", arguments: [scope,id])
            }
            if body.page.next_offset == nil || old == nil || old?.body.page.snapshot == body.page.snapshot {
                try db.execute(sql: "INSERT INTO mobile_mirror_bodies(scope,threadId,value) VALUES(?,?,?) ON CONFLICT(scope,threadId) DO UPDATE SET value=excluded.value",
                    arguments: [scope,id,try JSONEncoder().encode(value)])
                try Self.saveHistoryPreview(thread, scope: scope, in: db)
            }
        }
    }

    func threads(scope: String) throws -> [Thread] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT value FROM mobile_threads WHERE scope=?", arguments: [scope])
                .map { try JSONDecoder().decode(Thread.self, from: $0) }
        }
    }

    func selectedThread(scope: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT threadId FROM mobile_selection WHERE scope=?", arguments: [scope])
        }
    }

    func selectThread(_ id: String?, scope: String) throws {
        try db.write { db in
            if let id {
                try db.execute(sql: "INSERT INTO mobile_selection(scope,threadId) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET threadId=excluded.threadId", arguments: [scope, id])
            } else {
                try db.execute(sql: "DELETE FROM mobile_selection WHERE scope=?", arguments: [scope])
            }
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

    func setPinned(_ pinned: Bool, threadId: String, scope: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE mobile_threads SET pinned=? WHERE scope=? AND threadId=?",
                arguments: [pinned, scope, threadId])
        }
    }

    func metadata(scope: String) throws -> [String: ThreadSyncMetadata] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.threadId,t.pinned,t.readCursor,h.value AS history FROM mobile_threads t
                LEFT JOIN mobile_mirror_bodies h ON t.scope=h.scope AND t.threadId=h.threadId WHERE t.scope=?
                """, arguments: [scope])
            return try Dictionary(uniqueKeysWithValues: rows.map { row in
                let data: Data? = row["history"]
                let cached = try data.map { try JSONDecoder().decode(MirrorCachedBody.self, from: $0) }
                let read: Int = row["readCursor"]
                return (row["threadId"], ThreadSyncMetadata(lastSyncedAt: cached?.downloadedAt,
                    unreadMessages: max(0, (cached?.body.messages.count ?? 0) - read - 1),
                    pinned: row["pinned"], isPartial: cached?.body.isPartial ?? true))
            })
        }
    }
    func markRead(_ id: String, scope: String) throws {
        let count = try mirrorBody(id, scope: scope)?.body.messages.count ?? 0
        try db.write { db in
            try db.execute(sql: "UPDATE mobile_threads SET readCursor=? WHERE scope=? AND threadId=?", arguments: [count - 1,scope,id])
        }
    }
}
