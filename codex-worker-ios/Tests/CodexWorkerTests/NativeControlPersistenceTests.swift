import Foundation
import Testing
@testable import CodexWorker

/// Production GRDB cache and receipt validation with isolated transport data.
/// No API/AI stub, native write, pending request, or production data mutation.
struct NativeControlPersistenceTests {
    private let thread = "native-control-test-thread"
    private let scope = "isolated-control-account"

    @Test func durableIntentSurvivesReopenAndRejectsSecondAttempt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let first = try MobileSyncCache(path: path)
        let pending = attempt()
        let initial = try await first.beginControlAttempt(pending, text: "保留原文", threadId: thread, scope: scope)
        #expect(initial.controlAttempt?.isUncertain == true)
        let reopened = try MobileSyncCache(path: path)
        let restored = try await reopened.composer(threadId: thread, scope: scope)
        #expect(restored?.controlAttempt == initial.controlAttempt)
        #expect(restored?.text == "保留原文")
        #expect(try await reopened.composer(threadId: thread, scope: "other-account") == nil)
        do {
            _ = try await reopened.beginControlAttempt(attempt(id: "different-attempt"), text: "不能重复", threadId: thread, scope: scope)
            Issue.record("A retained uncertain submission must block another write intent")
        } catch CodexError.invalidState {}
    }

    @Test func delayedDraftCannotEraseIntentOrAcceptedReceipt() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let stale = ComposerDraft(text: "旧草稿", editedAt: Date(timeIntervalSince1970: 1))
        let pending = attempt()
        _ = try await cache.beginControlAttempt(pending, text: "保留原文", threadId: thread, scope: scope)
        try await cache.saveComposer(stale, threadId: thread, scope: scope)
        #expect(try await cache.composer(threadId: thread, scope: scope)?.text == "保留原文")
        _ = try await cache.reconcileControlAttempt(id: pending.request.submission_id, receipt: accepted(pending), threadId: thread, scope: scope)
        try await cache.saveComposer(stale, threadId: thread, scope: scope)
        let final = try await cache.composer(threadId: thread, scope: scope)
        #expect(final?.text == "")
        #expect(final?.controlAttempt?.receipt?.status == "accepted")
    }

    @Test func lateReceiptPreservesNewDraftAndOtherTask() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let pending = attempt()
        _ = try await cache.beginControlAttempt(pending, text: "保留原文", threadId: thread, scope: scope)
        try await cache.saveComposer(.init(text: "下一条新草稿"), threadId: thread, scope: scope)
        try await cache.saveComposer(.init(text: "另一个任务"), threadId: "other-thread", scope: scope)
        let result = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        #expect(result.text == "下一条新草稿")
        #expect(result.controlAttempt?.receipt?.status == "accepted")
        #expect(try await cache.composer(threadId: "other-thread", scope: scope)?.text == "另一个任务")
        let next = attempt(id: "newer-attempt")
        _ = try await cache.beginControlAttempt(next, text: "下一条新草稿", threadId: thread, scope: scope)
        let unchanged = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        #expect(unchanged.controlAttempt?.request.submission_id == next.request.submission_id)
        #expect(unchanged.controlAttempt?.isUncertain == true)
    }

    @Test func receiptsRequireOriginalSubmissionThreadAndExactStoppedTurn() throws {
        let pending = attempt()
        var receipt = accepted(pending)
        #expect(pending.validates(receipt, threadID: thread))
        receipt.thread_id = "other-thread"
        #expect(!pending.validates(receipt, threadID: thread))
        receipt = accepted(pending); receipt.submission_id = "other-submission"
        #expect(!pending.validates(receipt, threadID: thread))
        let stop = NativeControlAttempt(operation: .interrupt,
            request: .init(submission_id: "stop-attempt", control_receipt: "receipt", control_version: "version",
                           expected_turn_id: "observed-turn"), attemptedAt: Date())
        var result = NativeControlReceipt(submission_id: "stop-attempt", thread_id: thread, operation: "interrupt",
                                         status: "not_interrupted", turn_id: nil)
        #expect(stop.validates(result, threadID: thread))
        result.status = "interrupted"
        #expect(!stop.validates(result, threadID: thread))
        result.turn_id = "different-turn"
        #expect(!stop.validates(result, threadID: thread))
        result.turn_id = "observed-turn"; result.goal_pause_error = "pause unconfirmed"
        #expect(stop.validates(result, threadID: thread))
        #expect(try JSONDecoder().decode(NativeControlReceipt.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test func sameTextEditedAfterSubmissionIsStillANewDraft() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let pending = attempt()
        let sealed = try await cache.beginControlAttempt(pending, text: "保留原文", threadId: thread, scope: scope)
        try await cache.saveComposer(.init(text: "中间编辑"), threadId: thread, scope: scope)
        try await cache.saveComposer(.init(text: "保留原文"), threadId: thread, scope: scope)
        let newer = try await cache.composer(threadId: thread, scope: scope)
        #expect(newer?.textRevision != sealed.controlAttempt?.draftTextRevision)
        let final = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        #expect(final.text == "保留原文")
        #expect(final.controlAttempt?.receipt?.status == "accepted")
    }

    @Test func knownReceiptCannotBeDowngradedByLateUnknownOrFailure() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let pending = attempt()
        _ = try await cache.beginControlAttempt(pending, text: "保留原文", threadId: thread, scope: scope)
        let terminal = accepted(pending)
        _ = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: terminal, threadId: thread, scope: scope)
        var unknown = terminal; unknown.status = "unknown"; unknown.turn_id = nil
        let lateRead = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: unknown, threadId: thread, scope: scope)
        #expect(lateRead.controlAttempt?.receipt == terminal)
        let lateFailure = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            localRejection: "LATE_TRANSPORT_ERROR", threadId: thread, scope: scope)
        #expect(lateFailure.controlAttempt?.receipt == terminal)
        #expect(lateFailure.controlAttempt?.localRejection == nil)
        #expect(lateFailure.controlAttempt?.isUncertain == false)
        var conflict = terminal; conflict.turn_id = "different-native-turn"
        do {
            _ = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
                receipt: conflict, threadId: thread, scope: scope)
            Issue.record("Conflicting terminal receipts must not replace the original result")
        } catch CodexError.invalidState {}
        #expect(try await cache.composer(threadId: thread, scope: scope)?.controlAttempt?.receipt == terminal)
    }

    @Test func receiptBeforeQueuedNewEditDoesNotDiscardTheEdit() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let original = ComposerDraft(text: "保留原文", editedAt: Date(timeIntervalSince1970: 1), textRevision: "original-edit")
        try await cache.saveComposer(original, threadId: thread, scope: scope)
        let pending = attempt()
        _ = try await cache.beginControlAttempt(pending, text: original.text,
            textRevision: original.textRevision, editedAt: original.editedAt, threadId: thread, scope: scope)
        // This edit exists before the receipt, but its ordinary save is queued.
        let queued = ComposerDraft(text: "下一条新草稿", editedAt: Date(timeIntervalSince1970: 2), textRevision: "queued-edit")
        _ = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        try await cache.saveComposer(queued, threadId: thread, scope: scope)
        let final = try await cache.composer(threadId: thread, scope: scope)
        #expect(final?.text == queued.text)
        #expect(final?.textRevision == queued.textRevision)
        #expect(final?.editedAt == queued.editedAt)
        #expect(final?.controlAttempt?.receipt?.status == "accepted")
    }

    @Test func consumedRevisionCannotReturnAfterANewerStopIntent() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let original = ComposerDraft(text: "保留原文", editedAt: Date(timeIntervalSince1970: 1), textRevision: "consumed-edit")
        try await cache.saveComposer(original, threadId: thread, scope: scope)
        let pending = attempt()
        _ = try await cache.beginControlAttempt(pending, text: original.text,
            textRevision: original.textRevision, editedAt: original.editedAt, threadId: thread, scope: scope)
        let cleared = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        let stop = NativeControlAttempt(operation: .interrupt,
            request: .init(submission_id: "next-stop", control_receipt: "receipt", control_version: "version",
                           expected_turn_id: "observed-turn"), attemptedAt: Date())
        _ = try await cache.beginControlAttempt(stop, text: cleared.text,
            textRevision: cleared.textRevision, editedAt: cleared.editedAt, threadId: thread, scope: scope)
        try await cache.saveComposer(original, threadId: thread, scope: scope)
        let final = try await cache.composer(threadId: thread, scope: scope)
        #expect(final?.text == "")
        #expect(final?.controlAttempt?.request.submission_id == "next-stop")
        #expect(final?.controlAttempt?.isUncertain == true)
    }

    @Test func beginSealsTheShownRevisionAndPreservesAlreadyStoredNewerText() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        // A user can edit back to identical text while an earlier operation is
        // completing off-screen. Equal text must not make it the submitted edit.
        let newer = ComposerDraft(text: "保留原文", editedAt: Date(timeIntervalSince1970: 2), textRevision: "newer-same-text")
        try await cache.saveComposer(newer, threadId: thread, scope: scope)
        let pending = attempt()
        let sealed = try await cache.beginControlAttempt(pending, text: "保留原文",
            textRevision: "shown-edit", editedAt: Date(timeIntervalSince1970: 1), threadId: thread, scope: scope)
        #expect(sealed.controlAttempt?.draftTextRevision == "shown-edit")
        #expect(sealed.textRevision == newer.textRevision)
        let final = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        #expect(final.text == newer.text)
        #expect(final.textRevision == newer.textRevision)
    }

    @Test func equalTimeOldBeginCannotReplaceANewerEditingRevision() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let time = Date(timeIntervalSince1970: 1)
        try await cache.saveComposer(.init(text: "更新正文", editedAt: time, textRevision: "newer-edit"), threadId: thread, scope: scope)
        let pending = attempt()
        let sealed = try await cache.beginControlAttempt(pending, text: "保留原文",
            textRevision: "older-shown-edit", editedAt: time, threadId: thread, scope: scope)
        #expect(sealed.text == "更新正文")
        #expect(sealed.textRevision == "newer-edit")
        #expect(sealed.controlAttempt?.draftTextRevision == "older-shown-edit")
    }

    @Test func legacyRevisionBindsAtomicallyWithoutReplacingAnEqualTimeNewEdit() async throws {
        let cache = try MobileSyncCache(path: ":memory:")
        let time = Date(timeIntervalSince1970: 1)
        try await cache.saveComposer(.init(text: "保留原文", editedAt: time, textRevision: nil), threadId: thread, scope: scope)
        let pending = attempt()
        let sealed = try await cache.beginControlAttempt(pending, text: "保留原文",
            textRevision: "bound-legacy-edit", editedAt: time, threadId: thread, scope: scope)
        #expect(sealed.textRevision == "bound-legacy-edit")
        #expect(sealed.editedAt == time)
        let accepted = try await cache.reconcileControlAttempt(id: pending.request.submission_id,
            receipt: accepted(pending), threadId: thread, scope: scope)
        #expect(accepted.text == "")
        #expect(accepted.controlAttempt?.receipt?.status == "accepted")
    }

    @Test func exactStopContractKeepsDescendantRiskSeparateFromGoalPause() throws {
        var observation = NativeControlObservation(thread_id: thread, host_id: "local", owner_client_id: "original-entry-owner",
            protocol: "plain-text-local-v2", status: "running", reply_route: "steer", input_available: true,
            stop_available: true, active_turn_id: "observed-turn", control_receipt: String(repeating: "a", count: 64),
            control_version: String(repeating: "b", count: 64), steer_semantics: "current-task-may-follow-new-active-turn",
            stop_mode: "user-stop", stop_pauses_goal: false, stop_may_interrupt_active_thread_descendants: true)
        let decoded = try JSONDecoder().decode(NativeControlObservation.self, from: JSONEncoder().encode(observation))
        #expect(decoded.validates(threadID: thread) && decoded.canStop)
        #expect(!decoded.stop_pauses_goal && decoded.stop_may_interrupt_active_thread_descendants)
        observation.stop_pauses_goal = true
        #expect(!observation.canStop)
        observation.protocol = "plain-text-local-v1"
        #expect(!observation.validates(threadID: thread))
    }

    private func attempt(id: String = "control-attempt") -> NativeControlAttempt {
        .init(operation: .input,
              request: .init(submission_id: id, control_receipt: "receipt", control_version: "version", text: "保留原文"),
              attemptedAt: Date())
    }

    private func accepted(_ attempt: NativeControlAttempt) -> NativeControlReceipt {
        .init(submission_id: attempt.request.submission_id, thread_id: thread, operation: "start",
              status: "accepted", turn_id: "returned-native-turn")
    }
}
