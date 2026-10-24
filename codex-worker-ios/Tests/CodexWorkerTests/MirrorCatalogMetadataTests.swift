import Foundation
import Testing
@testable import CodexWorker

struct MirrorCatalogMetadataTests {
    @Test
    func readableHistoryCannotRollBackCatalogMetadata() async throws {
        for checkpointed in [true, false] {
            let cache = try MobileSyncCache(path: ":memory:")
            let old = body(count: 2, next: nil)
            try await save(old, to: cache, checkpointed: checkpointed)
            let current = index()
            try await cache.saveMirrorIndex(current, scope: "account")
            // Re-reading an unchanged complete snapshot is a normal sync path.
            try await save(old, to: cache, checkpointed: checkpointed)
            var expected = current.threads[0].thread(in: current.namespace)
            expected.preview = "saved reply 1"
            let threads = try await cache.threads(scope: "account")
            let history = try await cache.mirrorBody("thread", scope: "account")
            #expect(threads == [expected])
            #expect(history?.body == old)
        }
    }

    @Test
    func historyFallbackAndFurtherPreviewRemainReadable() async throws {
        for checkpointed in [true, false] {
            let cache = try MobileSyncCache(path: ":memory:")
            let first = body(count: 1, next: 1)
            try await save(first, to: cache, checkpointed: checkpointed)
            var fallback = first.thread.thread(in: first.namespace)
            fallback.preview = "saved reply 0"
            #expect(try await cache.threads(scope: "account") == [fallback])
            let current = index()
            try await cache.saveMirrorIndex(current, scope: "account")
            let complete = body(count: 2, next: nil)
            try await save(complete, to: cache, checkpointed: checkpointed)
            var expected = current.threads[0].thread(in: current.namespace)
            expected.preview = "saved reply 1"
            #expect(try await cache.threads(scope: "account") == [expected])
            #expect(try await cache.mirrorBody("thread", scope: "account")?.body == complete)
        }
    }

    private func save(_ body: MirrorBody, to cache: MobileSyncCache, checkpointed: Bool) async throws {
        if checkpointed { try await cache.saveMirrorProgress(body, scope: "account") }
        else { try await cache.saveMirrorBody(body, scope: "account") }
    }

    private func index() -> MirrorIndex {
        MirrorIndex(ok: true, namespace: "source", source: "local_mirror", threads: [
            MirrorThread(thread_id: "thread", host_id: "current-host", metadata: [
                "title": .string("Current task title"),
                "createdAt": .string("2026-09-24T09:02:40Z"),
                "updatedAt": .string("2026-10-24T19:00:27Z"),
                // A cleared catalog value must not be filled from an older snapshot.
                "cwd": .null
            ])
        ])
    }

    private func body(count: Int, next: Int?) -> MirrorBody {
        MirrorBody(ok: true, namespace: "source", source: "local_mirror",
            thread: MirrorThread(thread_id: "thread", host_id: "old-host", metadata: [
                "title": .string("Old task title"),
                "createdAt": .string("2026-09-24T09:02:40Z"),
                "updatedAt": .string("2026-10-24T18:19:57Z"),
                "cwd": .string("/old/directory")
            ], content_coverage: .string("partial")),
            messages: (0..<count).map {
                MirrorMessage(native_id: "message-\($0)", role: "assistant", text_content: "saved reply \($0)")
            }, items: [], attachments: [],
            page: MirrorPage(offset: 0, limit: 1, local_total: 2,
                snapshot: "unchanged-snapshot", next_offset: next, scope: "local_only"))
    }
}
