import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

/// State/presentation guards only. No API/AI stub or returned effect is executed.
@MainActor
struct ReplyHistoryPresentationTests {
    private func configured<T>(_ body: (WorkerConfiguration) throws -> T) throws -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overlay = previous
        let configuration = WorkerConfiguration.default
        overlay["codex.worker.configuration"] = try JSONEncoder().encode(configuration)
        // This process-only overlay never saves or changes the normal App's configuration.
        defaults.setVolatileDomain(overlay, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        return try body(configuration)
    }

    private func selected(_ configuration: WorkerConfiguration) throws -> ChatFeature.State {
        var thread = CodexWorker.Thread(threadId: "original-thread", preview: nil, cwd: nil,
            createdAt: nil, updatedAt: nil, modelProvider: nil)
        thread.origin = .init(namespace: "schema-only-source", hostID: "mirror-origin")
        let account = MobileSyncEngine.scope(configuration: configuration)
        let attempt = NativeControlAttempt(operation: .input, request: .init(submission_id: "accepted-A",
            control_receipt: "receipt", control_version: "version", text: "原文"), attemptedAt: Date(),
            receipt: .init(submission_id: "accepted-A", thread_id: thread.threadId,
                operation: "start", status: "accepted", turn_id: "original-turn"), accountScope: account)
        var state = ChatFeature.State()
        state.activeThread = thread; state.controlAccount = account; state.controlAttempt = attempt
        state.composerScope = MobileSyncEngine.threadScope(for: thread, configuration: configuration)
        state.replyHistoryRefresh = try #require(ReplyHistoryRefresh(identity: thread.id, account: account, attempt: attempt))
        state.inputText = "保留新草稿"; state.composerTextRevision = "newer-revision"; state.composerEditOrdinal = 900
        return state
    }

    @Test
    func acceptedAWaitingCannotHideRejectedOrLocallyRejectedB() throws {
        try configured { configuration in
            let original = try selected(configuration)
            #expect(original.controlAttemptMessage == "已提交 · 等待回复更新…")
            for local in [false, true] {
                var state = original
                var rejected = try #require(state.controlAttempt)
                rejected.request.submission_id = "rejected-B"
                rejected.receipt = local ? nil : .init(submission_id: "rejected-B", thread_id: "original-thread",
                    operation: "start", status: "rejected")
                rejected.localRejection = local ? "NATIVE_CONTROL_CHANGED" : nil
                state.controlAttempt = rejected
                #expect(state.replyHistoryRefresh != nil) // Deliberately retain stale A to exercise the UI gate.
                #expect(state.controlAttemptMessage == "本次未发送，原文已保留。")
            }
        }
    }

    @Test
    func acceptedAWaitingCannotHideLocalStopResults() throws {
        try configured { configuration in
            let original = try selected(configuration)
            for (status, message) in [
                ("interrupted", "本轮已停止；子任务清理结果尚未确认。"),
                ("not_interrupted", "未停止任何执行，请刷新状态。")
            ] {
                var state = original
                var stop = try #require(state.controlAttempt)
                stop.operation = .interrupt; stop.request.submission_id = "stop-B"
                stop.request.expected_turn_id = "original-turn"
                stop.receipt = .init(submission_id: "stop-B", thread_id: "original-thread", operation: "interrupt",
                    status: status, turn_id: status == "interrupted" ? "original-turn" : nil)
                state.controlAttempt = stop
                #expect(state.controlAttemptMessage == message)
            }
        }
    }

    @Test
    func matchingSourceSuccessAppliesMessagesAndClosesWaitingWithoutChangingDraft() throws {
        try configured { configuration in
            var state = try selected(configuration)
            let thread = try #require(state.activeThread)
            let account = try #require(state.controlAccount)
            let history = ThreadHistory(threadIdentity: thread.id, messages: [
                .init(id: "native-final", role: "assistant", text: "来源最终正文", sentAt: nil,
                    turnID: "original-turn", phase: "final_answer", turnStatus: "completed",
                    contextSnapshotSHA256: String(repeating: "d", count: 64), hasNonemptySourceText: true)
            ], records: [], attachments: [], downloadedAt: Date(), isPartial: true, hasMore: false,
                availableMessageCount: 1, refreshRequested: false)
            state.replyHistoryReadID = "matching-read"; state.isHistorySyncing = true
            state.replyHistoryRefresh?.pending = false
            _ = ChatFeature().reduce(into: &state, action: .replyHistoryResponse(readID: "matching-read",
                identity: thread.id, account: account, submissionID: "accepted-A", turnID: "original-turn", .success(history)))
            #expect(state.history == history && state.messages.map(\.text) == ["来源最终正文"])
            #expect(state.replyHistoryReadID == nil && !state.isHistorySyncing && state.replyHistoryRefresh?.isAwaitingResponse == false)
            #expect(state.inputText == "保留新草稿" && state.composerTextRevision == "newer-revision" && state.composerEditOrdinal == 900)
        }
    }
}
