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

    private func idle() -> NativeControlObservation {
        .init(thread_id: "original-thread", host_id: "local", owner_client_id: "owner",
            protocol: "plain-text-local-v2", status: "idle", input_available: true,
            stop_available: false, control_receipt: String(repeating: "a", count: 64),
            control_version: String(repeating: "b", count: 64),
            steer_semantics: "current-task-may-follow-new-active-turn", stop_mode: "user-stop",
            stop_pauses_goal: false, stop_may_interrupt_active_thread_descendants: true)
    }

    @Test
    func onlyAcceptedInputCreatesAReadRequest() throws {
        let attempt = accepted()
        let refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        #expect(refresh.pending && !refresh.observedIdle)
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
    func idleQueuesOneReadAndDoesNotRepeatOrFollowAnotherSubmission() throws {
        let attempt = accepted()
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        refresh.pending = false
        var other = attempt; other.request.submission_id = "other"; other.receipt?.submission_id = "other"
        refresh.observeIdle(idle(), attempt: other)
        #expect(!refresh.pending && !refresh.observedIdle)
        refresh.observeIdle(idle(), attempt: attempt)
        #expect(refresh.pending && refresh.observedIdle)
        refresh.pending = false
        refresh.observeIdle(idle(), attempt: attempt)
        #expect(!refresh.pending && refresh.observedIdle)
    }

    @Test
    func remoteIntentDoesNotFollowAnObservationFromAnotherExecutionContext() throws {
        var attempt = accepted()
        let context = NativeControlExecutionContext(protocolName: "plain-text-ssh-v1", hostID: "remote-host",
            nativeHostID: "local", sourceNamespace: "source", machine: "machine", binding: String(repeating: "c", count: 64))
        attempt.executionContext = context
        attempt.receipt?.protocol = context.protocolName; attempt.receipt?.host_id = context.hostID
        attempt.receipt?.native_host_id = context.nativeHostID; attempt.receipt?.source_namespace = context.sourceNamespace
        attempt.receipt?.execution_machine = context.machine; attempt.receipt?.execution_binding = context.binding
        var refresh = try #require(ReplyHistoryRefresh(identity: "identity", account: "original-account", attempt: attempt))
        refresh.pending = false
        refresh.observeIdle(idle(), attempt: attempt)
        #expect(!refresh.pending && !refresh.observedIdle)
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
