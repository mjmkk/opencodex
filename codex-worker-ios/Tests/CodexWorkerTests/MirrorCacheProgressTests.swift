import Foundation
import Testing
@testable import CodexWorker

struct MirrorCacheProgressTests {
    @Test
    func lateFirstPageCannotEraseAlreadyReadablePages() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        try await cache.saveMirrorProgress(body("same", count: 4, next: 4), scope: "account")
        try await cache.saveMirrorProgress(body("same", count: 1, next: 1), scope: "account")
        let readable = try await cache.mirrorBody("thread", scope: "account")
        let checkpoint = try await cache.mirrorStaging("thread", scope: "account")
        #expect(readable?.body.messages.count == 4)
        #expect(readable?.history.hasMore == true)
        #expect(checkpoint?.page.next_offset == 4)
    }

    @Test
    func latePartialPageCannotReopenCompletedHistory() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        try await cache.saveMirrorProgress(body("same", count: 6, next: nil), scope: "account")
        try await cache.saveMirrorProgress(body("same", count: 1, next: 1), scope: "account")
        let readable = try await cache.mirrorBody("thread", scope: "account")
        let checkpoint = try await cache.mirrorStaging("thread", scope: "account")
        #expect(readable?.body.messages.count == 6)
        #expect(readable?.history.hasMore == false)
        #expect(checkpoint == nil)
    }

    @Test
    func replacementKeepsOldHistoryUntilItsOwnDownloadCompletes() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        try await cache.saveMirrorProgress(body("old", count: 6, next: nil), scope: "account")
        try await cache.saveMirrorProgress(body("new", count: 4, next: 4), scope: "account")
        try await cache.saveMirrorProgress(body("new", count: 1, next: 1), scope: "account")
        let prior = try await cache.mirrorBody("thread", scope: "account")
        let checkpoint = try await cache.mirrorStaging("thread", scope: "account")
        #expect(prior?.body.page.snapshot == "old")
        #expect(checkpoint?.page.snapshot == "new")
        #expect(checkpoint?.page.next_offset == 4)
        try await cache.saveMirrorProgress(body("new", count: 6, next: nil), scope: "account")
        let replacement = try await cache.mirrorBody("thread", scope: "account")
        let completedCheckpoint = try await cache.mirrorStaging("thread", scope: "account")
        #expect(replacement?.body.page.snapshot == "new")
        #expect(replacement?.body.messages.count == 6)
        #expect(completedCheckpoint == nil)
    }

    private func body(_ snapshot: String, count: Int, next: Int?) -> MirrorBody {
        MirrorBody(ok: true, namespace: "source", source: "local_mirror",
            thread: MirrorThread(thread_id: "thread", content_coverage: .string("complete")),
            messages: (0..<count).map { MirrorMessage(native_id: "message-\($0)", role: "assistant", text_content: "record \($0)") },
            items: [], attachments: [],
            page: MirrorPage(offset: 0, limit: 1, local_total: 6, snapshot: snapshot, next_offset: next, scope: "local_only"))
    }
}
