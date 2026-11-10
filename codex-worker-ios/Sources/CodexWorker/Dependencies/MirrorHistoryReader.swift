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

    /// AGT-26 S6：手机打开线程只要最新一段。拉最新 limit 条，和本地缓存按 native_id 拼接：
    /// 新窗口第一条在缓存里能找到，就保留缓存里它前面的部分（之前已经翻过的更早消息不丢）；找不到就只留新窗口。
    /// 合并后 page.offset 表示本地窗口从第几条开始，大于 0 说明服务端还有更早的消息。
    static func syncTail(_ id: String, namespace: String, scope: String, cache: MobileSyncCache, offline: Bool, limit: Int = 200,
                         readWindow: @Sendable (Bool, Int?, Int) async throws -> MirrorBody) async throws -> MirrorBody {
        let old = try await cache.mirrorBody(id, scope: scope)?.body
        try Task.checkCancellation()
        var fresh = try await readWindow(offline, nil, limit)
        try validate(fresh, id: id, namespace: namespace)
        try Task.checkCancellation()
        fresh.items = []
        // 服务端还没拉到正文（第一次排队）时不要用空结果覆盖已有缓存
        if fresh.messages.isEmpty, let old, !old.messages.isEmpty {
            var kept = old; kept.refresh_requested = fresh.refresh_requested; return kept
        }
        if let old, let first = fresh.messages.first,
           let at = old.messages.firstIndex(where: { $0.native_id == first.native_id }), at > 0 {
            let ids = Set(fresh.messages.map(\.native_id))
            let prefix = old.messages[..<at].filter { !ids.contains($0.native_id) }
            fresh.messages = prefix + fresh.messages
            fresh.page.offset = max(0, fresh.page.offset - prefix.count)
        }
        fresh.page.next_offset = nil
        try await cache.saveMirrorWindow(fresh, scope: scope)
        return fresh
    }

    /// 往前再拉一段（“加载更早的消息”）。不带 snapshot：线程只会在末尾追加，前面的下标不变；按 native_id 去重
    static func loadEarlier(_ id: String, namespace: String, scope: String, cache: MobileSyncCache, limit: Int = 200,
                            readWindow: @Sendable (Bool, Int?, Int) async throws -> MirrorBody) async throws -> MirrorBody? {
        guard var body = try await cache.mirrorBody(id, scope: scope)?.body, body.page.offset > 0 else { return nil }
        let start = max(0, body.page.offset - limit)
        let page = try await readWindow(true, start, body.page.offset - start)
        try validate(page, id: id, namespace: namespace)
        try Task.checkCancellation()
        let ids = Set(body.messages.map(\.native_id))
        body.messages = page.messages.filter { !ids.contains($0.native_id) } + body.messages
        body.page.offset = start
        body.page.local_total = max(body.page.local_total, page.page.local_total)
        try await cache.saveMirrorWindow(body, scope: scope)
        return body
    }

    private static func validate(_ body: MirrorBody, id: String, namespace: String) throws {
        guard body.ok, body.source == "local_mirror", body.namespace == namespace,
              body.thread.thread_id == id, body.page.scope == "local_only" else { throw CodexError.invalidState }
    }
}
