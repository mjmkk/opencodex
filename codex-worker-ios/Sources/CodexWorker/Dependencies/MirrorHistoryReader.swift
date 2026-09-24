import Foundation

/// Bounded HTTP pagination over the existing cache, not a second history lifecycle.
enum MirrorHistoryReader {
    static func sync(_ id: String, namespace: String, scope: String, cache: MobileSyncCache,
                     offline: Bool, maxPages: Int,
                     validateAccount: @Sendable () throws -> Void,
                     readPage: @Sendable (Bool, Int, String?) async throws -> MirrorBody) async throws -> MirrorBody {
        guard maxPages > 0 else { throw CodexError.invalidState }
        let old = try await cache.mirrorBody(id, scope: scope)?.body
        var body = try await cache.mirrorStaging(id, scope: scope)
        var pagesRead = 0
        do {
            if body == nil {
                try validateAccount(); try Task.checkCancellation()
                let first = try await readPage(offline, 0, nil)
                try validate(first, id: id, namespace: namespace)
                guard first.page.offset == 0 else { throw CodexError.invalidState }
                pagesRead = 1
                if var old, old.page.snapshot == first.page.snapshot {
                    old.refresh_requested = first.refresh_requested
                    body = old
                } else { body = first }
                try validateAccount(); try Task.checkCancellation()
                try await cache.saveMirrorProgress(body!, scope: scope)
            }
            guard var progress = body else { throw CodexError.invalidState }
            try validate(progress, id: id, namespace: namespace)
            while pagesRead < maxPages, let offset = progress.page.next_offset {
                try validateAccount(); try Task.checkCancellation()
                let next = try await readPage(pagesRead == 0 ? offline : true, offset, progress.page.snapshot)
                try validate(next, id: id, namespace: namespace)
                try progress.append(next)
                try validateAccount(); try Task.checkCancellation()
                // Every accepted page survives both the per-refresh budget and a disconnect.
                try await cache.saveMirrorProgress(progress, scope: scope)
                pagesRead += 1
            }
            try validateAccount(); try Task.checkCancellation()
            guard let readable = try await cache.mirrorBody(id, scope: scope)?.body else { throw CodexError.invalidState }
            return readable
        } catch {
            // A rejected snapshot cannot be resumed. Other errors retain its checkpoint.
            if let failure = error as? CodexError {
                switch failure {
                case .cursorExpired, .invalidState, .apiError(code: "snapshot_changed", message: _):
                    try await cache.discardMirrorStaging(id, scope: scope)
                default: break
                }
            }
            throw error
        }
    }

    private static func validate(_ body: MirrorBody, id: String, namespace: String) throws {
        guard body.ok, body.source == "local_mirror", body.namespace == namespace,
              body.thread.thread_id == id, body.page.scope == "local_only" else { throw CodexError.invalidState }
    }
}
