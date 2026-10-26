import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ReplyHistoryRefreshTests {
    private func accepted() -> NativeControlAttempt {
        .init(operation: .input, request: .init(submission_id: "original-submission",
            control_receipt: "receipt", control_version: "version", text: "原文"), attemptedAt: Date(),
            receipt: .init(submission_id: "original-submission", thread_id: "original-thread",
                operation: "start", status: "accepted", turn_id: "original-turn"), accountScope: "original-account")
    }

    private func history() -> ThreadHistory {
        let context = String(repeating: "d", count: 64)
        return .init(threadIdentity: "identity", messages: [
            .init(id: "native-user", role: "user", text: "原文", sentAt: nil,
                turnID: "original-turn", turnStatus: "completed", contextSnapshotSHA256: context),
            .init(id: "native-assistant", role: "assistant", text: "真实来源正文", sentAt: nil,
                turnID: "original-turn", phase: "final_answer", turnStatus: "completed", contextSnapshotSHA256: context,
                hasNonemptySourceText: true)
        ], records: [], attachments: [], downloadedAt: Date(), isPartial: true, hasMore: false,
            availableMessageCount: 2, refreshRequested: true)
    }

    @Test
    func onlyAcceptedInputCreatesAReadRequest() throws {
        let attempt = accepted()
        let refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        #expect(refresh.pending && refresh.isAwaitingResponse)
        #expect(ReplyHistoryRefresh(identity: "identity", account: "other-account", attempt: attempt) == nil)
        var unknown = attempt; unknown.receipt = nil
        #expect(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: unknown) == nil)
        var rejected = attempt; rejected.receipt?.status = "rejected"
        #expect(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: rejected) == nil)
        var stop = attempt; stop.operation = .interrupt
        #expect(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: stop) == nil)
        var mismatched = attempt; mismatched.receipt?.submission_id = "different-submission"
        #expect(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: mismatched) == nil)
    }

    @Test
    func foregroundCadenceKeepsReadingUntilTheSourceReplyAppears() throws {
        let attempt = accepted()
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        refresh.pending = false
        refresh.requestRead()
        #expect(refresh.pending && refresh.isAwaitingResponse)
        refresh.pending = false
        var old = history(); old.messages = []
        refresh.observeHistory(old, attempt: attempt)
        refresh.requestRead()
        #expect(refresh.pending && refresh.isAwaitingResponse)
        refresh.observeHistory(history(), attempt: attempt)
        #expect(!refresh.pending && !refresh.isAwaitingResponse)
        refresh.requestRead()
        #expect(!refresh.pending)
    }

    @Test
    func sourceProofCannotFollowAnotherExecutionContextOrSubmission() throws {
        var attempt = accepted()
        let context = NativeControlExecutionContext(protocolName: "plain-text-ssh-v1", hostID: "remote-host",
            nativeHostID: "local", sourceNamespace: "source", machine: "machine", binding: String(repeating: "c", count: 64))
        attempt.executionContext = context
        attempt.receipt?.protocol = context.protocolName; attempt.receipt?.host_id = context.hostID
        attempt.receipt?.native_host_id = context.nativeHostID; attempt.receipt?.source_namespace = context.sourceNamespace
        attempt.receipt?.execution_machine = context.machine; attempt.receipt?.execution_binding = context.binding
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: accepted()))
        refresh.pending = false
        refresh.observeHistory(history(), attempt: attempt)
        #expect(!refresh.pending && refresh.isAwaitingResponse)
        var other = accepted(); other.request.submission_id = "other"; other.receipt?.submission_id = "other"
        refresh.observeHistory(history(), attempt: other)
        #expect(refresh.isAwaitingResponse)
    }

    @Test
    func partialPagesUnknownOrUnrelatedMessagesDoNotProveTheReply() throws {
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: accepted()))
        var incomplete = history(); incomplete.hasMore = true
        var missing = history(); missing.messages[1].turnID = nil
        var unrelated = history(); unrelated.messages[1].turnID = "another-turn"
        var unknownText = history(); unknownText.messages[1].hasNonemptySourceText = nil
        var invalidDigest = history(); invalidDigest.messages[1].contextSnapshotSHA256 = "unknown"
        var empty = history(); empty.messages[1].text = " \n"
        for value in [incomplete, missing, unrelated, unknownText, invalidDigest, empty] {
            refresh.observeHistory(value, attempt: accepted())
            #expect(refresh.isAwaitingResponse)
        }
    }

    @Test
    func completedCommentaryAndAnOldSteerReplyAreNotFinalEvidence() throws {
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: accepted()))
        var commentary = history(); commentary.messages[1].phase = "commentary"
        refresh.observeHistory(commentary, attempt: accepted())
        #expect(refresh.isAwaitingResponse)
        var missingPhase = history(); missingPhase.messages[1].phase = nil
        refresh.observeHistory(missingPhase, attempt: accepted())
        #expect(refresh.isAwaitingResponse)
        var steer = accepted(); steer.receipt?.operation = "steer"
        refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: steer))
        refresh.observeHistory(history(), attempt: steer)
        #expect(refresh.isAwaitingResponse)
    }

    @Test
    func legacyMirrorDecodesAndNewSourceContextSurvivesProjection() throws {
        let legacy = try JSONDecoder().decode(MirrorMessage.self, from: Data(#"{"native_id":"old","role":"assistant","text_content":"旧正文"}"#.utf8))
        #expect(legacy.turn_id == nil && legacy.phase == nil && legacy.context_snapshot_sha256 == nil)
        let value = #"{"ok":true,"namespace":"source","source":"local_mirror","thread":{"thread_id":"original-thread"},"messages":[{"native_id":"native-assistant","role":"assistant","text_content":"原始正文","turn_id":"original-turn","phase":"final_answer","turn_status":"completed","context_snapshot_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}],"items":[],"attachments":[],"page":{"offset":0,"limit":100,"local_total":1,"snapshot":"snapshot","scope":"local_only"}}"#
        let body = try JSONDecoder().decode(MirrorBody.self, from: Data(value.utf8))
        let roundTrip = try JSONDecoder().decode(MirrorBody.self, from: JSONEncoder().encode(body))
        let message = try #require(MirrorCachedBody(body: roundTrip, downloadedAt: Date()).history.messages.first)
        #expect(message.turnID == "original-turn" && message.phase == "final_answer" && message.turnStatus == "completed")
        #expect(message.contextSnapshotSHA256 == String(repeating: "d", count: 64) && message.text == "原始正文" && message.hasNonemptySourceText == true)
        let projected = MirrorCachedBody(body: roundTrip, downloadedAt: Date()).history
        var confirmed = try #require(ReplyHistoryRefresh(identity: projected.threadIdentity, account: "original-account", attempt: accepted()))
        confirmed.observeHistory(projected, attempt: accepted())
        #expect(!confirmed.isAwaitingResponse) // Only an assistant is required in the saved source window.
        var noText = roundTrip; noText.messages[0].text_content = nil
        let placeholder = MirrorCachedBody(body: noText, downloadedAt: Date()).history
        var waiting = try #require(ReplyHistoryRefresh(identity: placeholder.threadIdentity, account: "original-account", attempt: accepted()))
        waiting.observeHistory(placeholder, attempt: accepted())
        #expect(waiting.isAwaitingResponse && placeholder.messages[0].hasNonemptySourceText == false)
    }

    @Test
    func readBudgetExpiresWithoutInventingFailureAndReopeningDoesNotExtendIt() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        var attempt = accepted(); attempt.attemptedAt = started
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        for tick in 0..<15 {
            let now = started.addingTimeInterval(Double(tick * 20))
            refresh.requestRead(at: now)
            let began = refresh.beginRead(at: now)
            #expect(began)
        }
        refresh.requestRead(at: started.addingTimeInterval(299))
        let extraRead = refresh.beginRead(at: started.addingTimeInterval(299))
        #expect(!refresh.pending && !extraRead)
        #expect(refresh.isAwaitingResponse && refresh.readsStarted == 15)
        var reopened = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        reopened.requestRead(at: started.addingTimeInterval(300))
        #expect(!reopened.pending && !reopened.hasBudget(at: started.addingTimeInterval(300)))
        #expect(reopened.isAwaitingResponse && reopened.statusMessage == "已提交 · 回复仍待更新")
    }

    @Test
    func visibleCadenceQueuesHistoryWhileNativeControlIsBusyAndHiddenChatDoesNot() throws {
        var state = ChatFeature.State()
        state.activeThread = .init(threadId: "original-thread", preview: nil, cwd: nil,
            createdAt: nil, updatedAt: nil, modelProvider: nil)
        state.replyHistoryRefresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: accepted()))
        state.replyHistoryRefresh?.pending = false; state.isControlLoading = true
        let hidden = state
        _ = ChatFeature().reduce(into: &state, action: .pollControl)
        #expect(state == hidden)
        state.isControlVisible = true
        _ = ChatFeature().reduce(into: &state, action: .pollControl)
        #expect(state.replyHistoryRefresh?.pending == true && state.isControlLoading && state.controlReadID == nil)
    }

    // State reduction only; returned live network effects are never run by these two tests.
    @Test
    func backgroundRequeuesAnInFlightReadAndLateResultCannotClearTheNewRead() throws {
        var state = ChatFeature.State()
        state.replyHistoryRefresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: accepted()))
        state.replyHistoryRefresh?.pending = false; state.replyHistoryReadID = "old-read"
        state.isHistorySyncing = true
        let reducer = ChatFeature()
        _ = reducer.reduce(into: &state, action: .appDidEnterBackground)
        #expect(state.replyHistoryReadID == nil && !state.isHistorySyncing && state.replyHistoryRefresh?.pending == true)
        state.replyHistoryReadID = "new-read"; state.isHistorySyncing = true
        let before = state
        _ = reducer.reduce(into: &state, action: .replyHistoryResponse(readID: "old-read", identity: "identity",
            account: "original-account", submissionID: "original-submission", turnID: "original-turn", .failure(.timeout)))
        #expect(state == before)
    }

    @Test
    func changingSelectionDiscardsTheOldReadRequest() throws {
        var state = ChatFeature.State()
        state.replyHistoryRefresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: accepted()))
        state.replyHistoryReadID = "old-read"
        _ = ChatFeature().reduce(into: &state, action: .setActiveThread(nil))
        #expect(state.replyHistoryRefresh == nil && state.replyHistoryReadID == nil)
    }
}
