import ComposableArchitecture
import Foundation

/// A read request for one accepted input; it never changes the stored write intent.
struct ReplyHistoryRefresh: Equatable, Sendable {
    let identity: String
    let account: String
    let submissionID: String
    let turnID: String
    let route: String
    let executionContext: NativeControlExecutionContext?
    let deadline: Date
    var readsStarted = 0
    var pending = true
    var isAwaitingResponse = true

    init?(identity: String, account: String, attempt: NativeControlAttempt?) {
        guard let attempt, attempt.operation == .input, attempt.localRejection == nil,
              attempt.accountScope == nil || attempt.accountScope == account,
              let receipt = attempt.receipt, receipt.status == "accepted",
              attempt.validates(receipt, threadID: receipt.thread_id),
              let turnID = receipt.turn_id, !turnID.isEmpty else { return nil }
        self.identity = identity; self.account = account
        submissionID = attempt.request.submission_id; self.turnID = turnID
        route = receipt.operation
        executionContext = attempt.executionContext
        // This stored intent time survives app restarts; reopening cannot extend the window.
        deadline = attempt.attemptedAt.addingTimeInterval(5 * 60)
    }

    func matches(_ other: Self) -> Bool {
        identity == other.identity && account == other.account
            && submissionID == other.submissionID && turnID == other.turnID && route == other.route
            && executionContext == other.executionContext
    }

    func hasBudget(at now: Date = Date()) -> Bool {
        isAwaitingResponse && readsStarted < 15 && now < deadline
    }

    var statusMessage: String? {
        guard isAwaitingResponse else { return nil }
        return hasBudget() ? "已提交 · 等待回复更新…" : "已提交 · 回复仍待更新"
    }

    mutating func requestRead(at now: Date = Date()) {
        pending = hasBudget(at: now)
    }

    mutating func beginRead(at now: Date = Date()) -> Bool {
        guard pending, hasBudget(at: now) else { return false }
        readsStarted += 1; pending = false
        return true
    }

    mutating func observeHistory(_ history: ThreadHistory, attempt: NativeControlAttempt?) {
        guard isAwaitingResponse, route == "start", history.threadIdentity == identity, !history.hasMore,
              let current = Self(identity: identity, account: account, attempt: attempt), matches(current) else { return }
        let visible = history.messages.contains { assistant in
            guard assistant.turnID == turnID, assistant.role == "assistant",
                  assistant.hasNonemptySourceText == true,
                  !assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  assistant.phase == "final_answer",
                  let context = assistant.contextSnapshotSHA256, NativeControlExecutionContext.isDigest(context) else { return false }
            return true
        }
        // Steer can reuse a turn containing older replies; it needs stronger source correlation.
        if visible { isAwaitingResponse = false; pending = false }
    }
}

extension ChatFeature {
    static func replyHistoryMatches(state: State, identity: String, account: String,
                                    submissionID: String, turnID: String) -> Bool {
        guard let thread = state.activeThread, thread.id == identity, state.currentComposerScope != nil,
              (try? MobileSyncEngine.scope()) == account,
              let attempt = state.controlAttempt, let receipt = attempt.receipt,
              attempt.validates(receipt, threadID: thread.threadId),
              let current = ReplyHistoryRefresh(identity: identity, account: account, attempt: state.controlAttempt),
              current.submissionID == submissionID, current.turnID == turnID,
              state.replyHistoryRefresh?.matches(current) == true else { return false }
        return true
    }

    static func scheduleReplyHistoryRefresh(state: State) -> Effect<Action> {
        guard state.isControlVisible, !state.isHistorySyncing, state.replyHistoryReadID == nil,
              let refresh = state.replyHistoryRefresh, refresh.hasBudget(), refresh.pending else { return .none }
        return .send(.refreshReplyHistory(identity: refresh.identity, account: refresh.account,
            submissionID: refresh.submissionID, turnID: refresh.turnID))
    }

    static func refreshReplyHistory(state: inout State, identity: String, account: String,
                                   submissionID: String, turnID: String) -> Effect<Action> {
        guard state.isControlVisible, !state.isHistorySyncing, state.replyHistoryReadID == nil,
              state.replyHistoryRefresh?.isAwaitingResponse == true,
              state.replyHistoryRefresh?.pending == true, let thread = state.activeThread,
              replyHistoryMatches(state: state, identity: identity, account: account,
                submissionID: submissionID, turnID: turnID) else { return .none }
        guard state.replyHistoryRefresh?.beginRead() == true else { return .none }
        let readID = UUID().uuidString
        state.replyHistoryReadID = readID; state.isHistorySyncing = true
        return .run { send in
            @Dependency(\.threadSyncClient) var sync
            do {
                let history = try await sync.syncHistory(thread, true)
                try Task.checkCancellation()
                await send(.replyHistoryResponse(readID: readID, identity: identity, account: account,
                    submissionID: submissionID, turnID: turnID, .success(history)))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await send(.replyHistoryResponse(readID: readID, identity: identity, account: account,
                    submissionID: submissionID, turnID: turnID, .failure(CodexError.from(error))))
            }
        }
    }
}

extension ChatFeature.State {
    var controlAttemptMessage: String? {
        if let refresh = replyHistoryRefresh,
           ChatFeature.replyHistoryMatches(state: self, identity: refresh.identity, account: refresh.account,
            submissionID: refresh.submissionID, turnID: refresh.turnID),
           let message = refresh.statusMessage { return message }
        return Self.controlReceiptMessage(controlAttempt)
    }

    private static func controlReceiptMessage(_ attempt: NativeControlAttempt?) -> String? {
        guard let attempt else { return nil }
        if attempt.localRejection != nil || attempt.receipt?.status == "rejected" {
            return attempt.operation == .interrupt ? "停止未执行，请刷新状态。" : "本次未发送，原文已保留。"
        }
        switch attempt.receipt?.status {
        case "accepted": return "回复已提交。"
        case "interrupted": return attempt.receipt?.goal_pause_error == nil ? "本轮已停止；子任务清理结果尚未确认。" : "本轮已停止；还有原生处理结果未确认。"
        case "not_interrupted": return "未停止任何执行，请刷新状态。"
        default: return nil
        }
    }

}
