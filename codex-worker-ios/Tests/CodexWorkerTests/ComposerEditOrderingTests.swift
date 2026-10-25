import Foundation
import GRDB
import Testing
@testable import CodexWorker

/// Deterministic edits using the real GRDB cache, with no clock/device/API mock.
struct ComposerEditOrderingTests {
    @Test func equalTimeNewEditPersistsInEitherSaveOrder() async throws {
        for reverse in [false, true] {
            let cache = try MobileSyncCache(path: ":memory:")
            let time = Date(timeIntervalSince1970: 1)
            let first = ComposerDraft(text: "先前编辑", editedAt: time)
            let second = ComposerDraft(text: "后来编辑", editedAt: time)
            for draft in reverse ? [second, first] : [first, second] {
                try await cache.saveComposer(draft, threadId: "same-time", scope: "isolated-edit-order")
            }
            let retained = try await cache.composer(threadId: "same-time", scope: "isolated-edit-order")
            #expect(retained?.text == second.text)
            #expect(retained?.textRevision == second.textRevision)
        }
    }

    @Test func laterEditWithEarlierTimestampSurvivesDelayedSave() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let first = ComposerDraft(text: "先前编辑", editedAt: Date(timeIntervalSince1970: 2))
        let second = ComposerDraft(text: "后来编辑", editedAt: Date(timeIntervalSince1970: 1))
        try await cache.saveComposer(second, threadId: "rollback", scope: "isolated-edit-order")
        try await cache.saveComposer(first, threadId: "rollback", scope: "isolated-edit-order")
        let retained = try await cache.composer(threadId: "rollback", scope: "isolated-edit-order")
        #expect(retained?.text == second.text)
        #expect(retained?.textRevision == second.textRevision)
    }

    @Test func queuedSameTextEditSurvivesAcceptanceEvenWhenItsClockWentBack() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let original = ComposerDraft(text: "相同正文", editedAt: Date(timeIntervalSince1970: 2))
        try await cache.saveComposer(original, threadId: "receipt", scope: "isolated-edit-order")
        let attempt = NativeControlAttempt(operation: .input,
            request: .init(submission_id: "original-attempt", control_receipt: "receipt", control_version: "version", text: original.text),
            attemptedAt: Date())
        _ = try await cache.beginControlAttempt(attempt, text: original.text,
            textRevision: original.textRevision, editedAt: original.editedAt, editOrdinal: original.editOrdinal,
            threadId: "receipt", scope: "isolated-edit-order")
        let queued = ComposerDraft(text: original.text, editedAt: Date(timeIntervalSince1970: 1))
        let receipt = NativeControlReceipt(submission_id: "original-attempt", thread_id: "receipt", operation: "start",
            status: "accepted", turn_id: "original-turn")
        let cleared = try await cache.reconcileControlAttempt(id: "original-attempt", receipt: receipt,
            threadId: "receipt", scope: "isolated-edit-order")
        #expect(cleared.text.isEmpty)
        try await cache.saveComposer(queued, threadId: "receipt", scope: "isolated-edit-order")
        try await cache.saveComposer(original, threadId: "receipt", scope: "isolated-edit-order")
        let retained = try await cache.composer(threadId: "receipt", scope: "isolated-edit-order")
        #expect(retained?.text == queued.text)
        #expect(retained?.textRevision == queued.textRevision)
        #expect(retained?.editOrdinal == queued.editOrdinal)
        #expect(retained?.controlAttempt?.receipt == receipt)
    }

    @Test func lateBeginCapturesOldOrderWithoutReplacingAnEqualTimeNewerEdit() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let time = Date(timeIntervalSince1970: 1)
        let shown = ComposerDraft(text: "已展示的编辑", editedAt: time)
        let newer = ComposerDraft(text: "后来的编辑", editedAt: time)
        try await cache.saveComposer(newer, threadId: "late-begin", scope: "isolated-edit-order")
        let attempt = NativeControlAttempt(operation: .input,
            request: .init(submission_id: "shown-attempt", control_receipt: "receipt", control_version: "version", text: shown.text),
            attemptedAt: Date())
        let retained = try await cache.beginControlAttempt(attempt, text: shown.text,
            textRevision: shown.textRevision, editedAt: shown.editedAt, editOrdinal: shown.editOrdinal,
            threadId: "late-begin", scope: "isolated-edit-order")
        #expect(retained.textRevision == newer.textRevision)
        #expect(retained.editOrdinal == newer.editOrdinal)
        #expect(retained.controlAttempt?.draftTextRevision == shown.textRevision)
        #expect(retained.controlAttempt?.draftEditOrdinal == shown.editOrdinal)
    }

    @Test func reopeningSeedsOrderFromDraftAndSealedAttempt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        _ = try MobileSyncCache(path: path)
        // Write a real persisted fixture directly, bypassing saveComposer's
        // in-process observation. Only reopening can discover this high water.
        let durableOrder: UInt64 = 1 << 60
        let attempt = NativeControlAttempt(operation: .input,
            request: .init(submission_id: "durable-attempt", control_receipt: "receipt", control_version: "version", text: "旧输入"),
            attemptedAt: Date(), draftTextRevision: "shown", draftEditOrdinal: durableOrder + 1)
        let persisted = ComposerDraft(text: "本地草稿", controlAttempt: attempt,
            textRevision: "local", editOrdinal: durableOrder)
        let db = try DatabaseQueue(path: path)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO mobile_composer_drafts(scope,threadId,value) VALUES(?,?,?)",
                arguments: ["isolated-edit-order", "reopen", try JSONEncoder().encode(persisted)])
        }
        let reopened = try MobileSyncCache(path: path)
        let next = ComposerDraft(text: "重开后的编辑")
        #expect(try #require(next.editOrdinal) > durableOrder + 1)
        #expect(try await reopened.composer(threadId: "reopen", scope: "isolated-edit-order") == persisted)
    }

    @Test func legacyReadBindsExactRowAndRejectsDelayedLegacySave() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let legacy = ComposerDraft(text: "原有草稿", editedAt: Date(timeIntervalSince1970: 1), textRevision: nil, editOrdinal: nil)
        try await cache.saveComposer(legacy, threadId: "legacy", scope: "isolated-edit-order")
        let bound = try #require(try await cache.composer(threadId: "legacy", scope: "isolated-edit-order"))
        #expect(bound.text == legacy.text)
        #expect(bound.textRevision != nil && bound.editOrdinal != nil)
        let newer = ComposerDraft(text: "新版编辑", editedAt: legacy.editedAt)
        try await cache.saveComposer(newer, threadId: "legacy", scope: "isolated-edit-order")
        try await cache.saveComposer(legacy, threadId: "legacy", scope: "isolated-edit-order")
        let retained = try await cache.composer(threadId: "legacy", scope: "isolated-edit-order")
        #expect(retained?.textRevision == newer.textRevision)
        #expect(retained?.editOrdinal == newer.editOrdinal)
    }

    @Test func exhaustedEditOrderNeverWrapsOrAllocatesAReplacement() {
        let order = ComposerEditOrder(highWater: UInt64.max - 1)
        #expect(order.next() == UInt64.max)
        #expect(order.next() == nil)
        order.observe(1)
        #expect(order.next() == nil)
    }
}
