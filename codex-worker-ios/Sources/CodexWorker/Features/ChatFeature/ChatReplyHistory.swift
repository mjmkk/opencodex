import ComposableArchitecture
import Foundation

/// A read request for one accepted input; it never changes the stored write intent.
struct ReplyHistoryRefresh: Equatable, Sendable {
    let identity: String
    let account: String
    let submissionID: String
    let turnID: String
    var pending = true
    var observedIdle = false

    init?(identity: String, account: String, attempt: NativeControlAttempt?) {
        guard let attempt, attempt.operation == .input, attempt.localRejection == nil,
              attempt.accountScope == nil || attempt.accountScope == account,
              let receipt = attempt.receipt, receipt.status == "accepted",
              attempt.validates(receipt, threadID: receipt.thread_id),
              let turnID = receipt.turn_id, !turnID.isEmpty else { return nil }
        self.identity = identity; self.account = account
        submissionID = attempt.request.submission_id; self.turnID = turnID
    }

    func matches(_ other: Self) -> Bool {
        identity == other.identity && account == other.account
            && submissionID == other.submissionID && turnID == other.turnID
    }

    mutating func observeIdle(_ observation: NativeControlObservation, attempt: NativeControlAttempt?) {
        guard !observedIdle, observation.status == "idle", let attempt,
              observation.executionContext == attempt.executionContext,
              let current = Self(identity: identity, account: account, attempt: attempt), matches(current) else { return }
        // Idle is only a reason to read the source again, not proof that our turn completed.
        observedIdle = true; pending = true
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
              let refresh = state.replyHistoryRefresh, refresh.pending else { return .none }
        return .send(.refreshReplyHistory(identity: refresh.identity, account: refresh.account,
            submissionID: refresh.submissionID, turnID: refresh.turnID))
    }

    static func refreshReplyHistory(state: inout State, identity: String, account: String,
                                   submissionID: String, turnID: String) -> Effect<Action> {
        guard state.isControlVisible, !state.isHistorySyncing, state.replyHistoryReadID == nil,
              state.replyHistoryRefresh?.pending == true, let thread = state.activeThread,
              replyHistoryMatches(state: state, identity: identity, account: account,
                submissionID: submissionID, turnID: turnID) else { return .none }
        let readID = UUID().uuidString
        state.replyHistoryReadID = readID; state.isHistorySyncing = true
        state.replyHistoryRefresh?.pending = false
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
