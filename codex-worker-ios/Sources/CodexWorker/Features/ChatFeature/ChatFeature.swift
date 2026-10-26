import ComposableArchitecture
import ExyteChat
import Foundation

@Reducer
public struct ChatFeature {
    private enum CancelID { case history, control }
    @ObservableState
    public struct State: Equatable {
        public var activeThread: Thread?
        public var messages: [Message] = []
        public var history: ThreadHistory?
        public var inputText = ""
        public var outgoing: ComposerSubmission?
        public var isSending = false
        public var errorMessage: String?
        public var isHistorySyncing = false
        public var lastSyncedAt: Date?
        public var composerScope: String?
        public var composerTextRevision: String?
        public var composerEditedAt: Date?
        public var composerEditOrdinal: UInt64?
        public var composerLoadID: String?
        public var controlObservation: NativeControlObservation?
        public var controlAccount: String?
        public var controlObservedAt: Date?
        public var controlAttempt: NativeControlAttempt?
        public var isControlLoading = false
        public var isControlPolling = false
        public var isControlVisible = false
        public var controlMessage: String?
        public var pendingControlOperation: NativeControlOperation?
        public var pendingControlID: String?
        public var controlReadID: String?
        public var isReceiptChecking = false
        var replyHistoryRefresh: ReplyHistoryRefresh?
        var replyHistoryReadID: String?
        public var hasUnconfirmedReply: Bool { outgoing != nil && outgoing?.acknowledgedReceiptID == nil }
        public var hasUncertainControl: Bool { controlAttempt?.isUncertain == true }
        public var canSend: Bool {
            isInputConnected
                && composerEditOrdinal != nil
                && !isSending && !isControlLoading && !hasUnconfirmedReply && !hasUncertainControl
        }
        public var isInputConnected: Bool { controlIsCurrent && controlObservation?.canInput == true }
        var currentComposerScope: String? {
            guard let thread = activeThread, let configuration = WorkerConfiguration.load(),
                  let composerScope,
                  composerScope == MobileSyncEngine.threadScope(for: thread, configuration: configuration) else { return nil }
            return composerScope
        }
        public var canStop: Bool {
            controlIsCurrent && controlObservation?.canStop == true
                && !isSending && !isControlLoading && !hasUncertainControl
        }
        private var controlIsCurrent: Bool {
            guard let thread = activeThread, let configuration = WorkerConfiguration.load() else { return false }
            return controlAccount == MobileSyncEngine.scope(configuration: configuration)
                && composerScope == MobileSyncEngine.threadScope(for: thread, configuration: configuration)
                && controlObservation?.validates(thread: thread) == true
        }
        public var hasNativeReviewWait: Bool { (activeThread?.pendingRequestCount ?? 0) > 0 }
        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear, onDisappear, appDidBecomeActive, appDidEnterBackground, refreshHistory
        case setActiveThread(Thread?)
        case historyResponse(identity: String, cached: Bool, Result<ThreadHistory, CodexError>)
        case syncMetadata(threadId: String, ThreadSyncMetadata?)
        case composerChanged(threadId: String, text: String)
        case composerLoaded(identity: String, scope: String, loadID: String, ComposerDraft)
        case acknowledgeUnknownReply
        case didSendDraft(DraftMessage)
        case refreshControl, pollControl, controlVisibilityChanged(Bool), sendReply, stopCurrentTurn, checkControlReceipt
        case controlResponse(identity: String, account: String, readID: String, Result<NativeControlObservation, CodexError>)
        case controlWillWrite(identity: String, account: String, operationID: String, ComposerDraft)
        case controlFinished(identity: String, account: String, operationID: String, Result<ComposerDraft, CodexError>)
        case refreshReplyHistory(identity: String, account: String, submissionID: String, turnID: String)
        case replyHistoryResponse(readID: String, identity: String, account: String, submissionID: String, turnID: String, Result<ThreadHistory, CodexError>)
        case clearError
    }
    public init() {}
    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear, .binding:
                return .none
            case .onDisappear:
                state.isControlVisible = false
                Self.invalidateControlRead(state: &state)
                return .cancel(id: CancelID.control)
            case .appDidEnterBackground:
                if state.replyHistoryReadID != nil { state.replyHistoryRefresh?.pending = true }
                state.replyHistoryReadID = nil
                state.isHistorySyncing = false
                state.isControlVisible = false
                Self.invalidateControlRead(state: &state)
                return .merge(.cancel(id: CancelID.history), .cancel(id: CancelID.control))
            case .appDidBecomeActive, .refreshHistory:
                guard let thread = state.activeThread else { return .none }
                guard state.replyHistoryReadID == nil else { return .none }
                state.isHistorySyncing = true
                let loadID = UUID().uuidString; state.composerLoadID = loadID
                let refreshSource = action.isExplicitRefresh
                return .merge(Self.load(thread, loadID: loadID, refreshSource: refreshSource)
                    .cancellable(id: CancelID.history, cancelInFlight: true),
                    action.isExplicitRefresh ? .none : .send(.pollControl))
            case .setActiveThread(let thread):
                if let thread, state.activeThread?.id == thread.id { state.activeThread = thread; return .none }
                state.activeThread = thread; state.messages = []; state.history = nil
                state.inputText = ""; state.outgoing = nil; state.isSending = false
                state.composerScope = nil; state.controlObservation = nil; state.controlAccount = nil
                state.composerTextRevision = nil; state.composerEditedAt = nil; state.composerEditOrdinal = nil
                state.composerLoadID = nil
                state.controlObservedAt = nil; state.controlAttempt = nil; state.controlMessage = nil
                state.replyHistoryRefresh = nil; state.replyHistoryReadID = nil
                state.isControlLoading = false; state.pendingControlOperation = nil
                state.isControlPolling = false
                state.pendingControlID = nil; state.controlReadID = nil
                state.isReceiptChecking = false
                state.errorMessage = nil; state.lastSyncedAt = nil; state.isHistorySyncing = thread != nil
                guard let thread else { return .merge(.cancel(id: CancelID.history), .cancel(id: CancelID.control)) }
                let loadID = UUID().uuidString; state.composerLoadID = loadID
                return .concatenate(.cancel(id: CancelID.control),
                    .merge(Self.load(thread, loadID: loadID).cancellable(id: CancelID.history, cancelInFlight: true), .send(.refreshControl)))
            case .historyResponse(let identity, let cached, let result):
                guard state.activeThread?.id == identity else { return .none }
                return Self.applyHistory(state: &state, cached: cached, result: result)
            case .syncMetadata(let id, let metadata):
                guard state.activeThread?.threadId == id else { return .none }
                state.lastSyncedAt = metadata?.lastSyncedAt
                return .none
            case .composerLoaded(let identity, let scope, let loadID, let draft):
                guard let thread = state.activeThread, thread.id == identity, !state.isSending,
                      state.composerLoadID == loadID, state.composerScope != scope,
                      let configuration = WorkerConfiguration.load(),
                      scope == MobileSyncEngine.threadScope(for: thread, configuration: configuration) else { return .none }
                state.inputText = draft.text; state.composerTextRevision = draft.textRevision
                state.composerEditedAt = draft.editedAt
                state.composerEditOrdinal = draft.editOrdinal
                state.composerScope = scope; state.outgoing = draft.outgoing
                state.controlAttempt = draft.controlAttempt
                // A write can finish after this cache snapshot was read but
                // before hydration. Reconcile a restored uncertain intent once;
                // this reads the original receipt and never repeats its POST.
                return draft.controlAttempt?.isUncertain == true ? .send(.checkControlReceipt) : .none
            case .composerChanged(let id, let text):
                guard let thread = state.activeThread, thread.threadId == id, !state.isSending,
                      !state.hasUnconfirmedReply, state.inputText != text,
                      let scope = state.currentComposerScope else { return .none }
                let draft = ComposerDraft(text: text, outgoing: state.outgoing, controlAttempt: state.controlAttempt)
                state.inputText = text; state.composerTextRevision = draft.textRevision
                state.composerEditedAt = draft.editedAt; state.composerEditOrdinal = draft.editOrdinal
                guard draft.editOrdinal != nil else {
                    state.controlMessage = "草稿暂未保存，请保留输入内容。"; return .none
                }
                return Self.saveDraft(draft, thread: thread, scope: scope)
            case .acknowledgeUnknownReply:
                guard let thread = state.activeThread, state.hasUnconfirmedReply, !state.isSending,
                      let scope = state.currentComposerScope else { return .none }
                state.inputText = state.outgoing?.body ?? state.inputText; state.outgoing = nil
                let draft = ComposerDraft(text: state.inputText, controlAttempt: state.controlAttempt)
                state.composerTextRevision = draft.textRevision; state.composerEditedAt = draft.editedAt
                state.composerEditOrdinal = draft.editOrdinal
                guard draft.editOrdinal != nil else {
                    state.controlMessage = "草稿暂未保存，请保留输入内容。"; return .none
                }
                return Self.saveDraft(draft, thread: thread, scope: scope)
            case .didSendDraft(let draft):
                let effect = Self.beginControl(state: &state, operation: .input, text: draft.text)
                return state.isSending ? .concatenate(.cancel(id: CancelID.control), effect) : effect
            case .sendReply:
                let text = state.inputText
                let effect = Self.beginControl(state: &state, operation: .input, text: text)
                return state.isSending ? .concatenate(.cancel(id: CancelID.control), effect) : effect
            case .stopCurrentTurn:
                let text = state.inputText
                let effect = Self.beginControl(state: &state, operation: .interrupt, text: text)
                return state.isSending ? .concatenate(.cancel(id: CancelID.control), effect) : effect
            case .controlVisibilityChanged(let visible):
                guard state.isControlVisible != visible else { return .none }
                state.isControlVisible = visible
                if visible { return .merge(.send(.pollControl), Self.scheduleReplyHistoryRefresh(state: state)) }
                Self.invalidateControlRead(state: &state)
                return .cancel(id: CancelID.control)
            case .pollControl:
                guard state.isControlVisible, !state.isSending, !state.isReceiptChecking,
                      !state.hasUncertainControl, !state.hasUnconfirmedReply,
                      !state.isControlLoading, !state.isControlPolling else { return .none }
                return Self.startControlRead(state: &state, quietly: true)
            case .refreshControl:
                guard !state.isSending, !state.isControlLoading else { return .none }
                return Self.startControlRead(state: &state, quietly: false)
            case .controlResponse(let identity, let account, let readID, let result):
                guard state.activeThread?.id == identity, state.controlReadID == readID else { return .none }
                Self.invalidateControlRead(state: &state)
                guard (try? MobileSyncEngine.scope()) == account else { state.controlObservation = nil; return .none }
                state.controlAccount = account
                switch result {
                case .success(let observation):
                    state.controlObservation = observation; state.controlObservedAt = Date()
                    state.controlMessage = nil
                    var refresh = state.replyHistoryRefresh
                    refresh?.observeIdle(observation, attempt: state.controlAttempt)
                    state.replyHistoryRefresh = refresh
                case .failure(.apiError(code: "NATIVE_THREAD_NOT_CONFIGURED", message: _)):
                    state.controlObservation = nil; state.controlMessage = "此任务的回复尚未接通，草稿会保留。"
                case .failure:
                    state.controlObservation = nil; state.controlMessage = "暂时无法核对执行状态，草稿会保留。"
                }
                return Self.scheduleReplyHistoryRefresh(state: state)
            case .controlWillWrite(let identity, let account, let operationID, let draft):
                guard state.activeThread?.id == identity, state.controlAccount == account,
                      state.pendingControlID == operationID else { return .none }
                state.controlAttempt = draft.controlAttempt
                return .none
            case .controlFinished(let identity, let account, let operationID, let result):
                guard let thread = state.activeThread, thread.id == identity,
                      state.pendingControlID == operationID
                        || (state.pendingControlID == nil && state.controlAttempt?.request.submission_id == operationID) else { return .none }
                state.isSending = false; state.pendingControlOperation = nil; state.pendingControlID = nil; state.isReceiptChecking = false
                guard (try? MobileSyncEngine.scope()) == account else {
                    state.controlObservation = nil; state.controlMessage = "连接已改变，请重新打开任务。"; return .none
                }
                switch result {
                case .success(let draft):
                    if let previous = state.controlAttempt, let incoming = draft.controlAttempt,
                       previous.request.submission_id == incoming.request.submission_id,
                       !previous.isUncertain {
                        guard (try? previous.reconciled(receipt: incoming.receipt,
                            localRejection: incoming.localRejection, threadID: thread.threadId)) == incoming else { return .send(.refreshControl) }
                    }
                    if let attempt = draft.controlAttempt, attempt.operation == .input,
                       state.composerTextRevision == attempt.draftTextRevision,
                       state.composerEditOrdinal == attempt.draftEditOrdinal,
                       state.inputText == attempt.request.text {
                        state.inputText = draft.text; state.composerTextRevision = draft.textRevision
                        state.composerEditedAt = draft.editedAt
                        state.composerEditOrdinal = draft.editOrdinal
                    }
                    state.controlAttempt = draft.controlAttempt
                    state.controlMessage = nil
                    if let refresh = ReplyHistoryRefresh(identity: identity, account: account, attempt: draft.controlAttempt),
                       state.replyHistoryRefresh?.matches(refresh) != true {
                        state.replyHistoryRefresh = refresh
                    }
                case .failure:
                    state.controlMessage = state.controlAttempt?.isUncertain == false ? nil
                        : "操作尚未完成，草稿和提交记录会保留。"
                }
                return .merge(.send(.refreshControl), Self.scheduleReplyHistoryRefresh(state: state))
            case .refreshReplyHistory(let identity, let account, let submissionID, let turnID):
                return Self.refreshReplyHistory(state: &state, identity: identity, account: account,
                    submissionID: submissionID, turnID: turnID)
                    .cancellable(id: CancelID.history, cancelInFlight: false)
            case .replyHistoryResponse(let readID, let identity, let account, let submissionID, let turnID, let result):
                guard state.replyHistoryReadID == readID else { return .none }
                state.replyHistoryReadID = nil; state.isHistorySyncing = false
                guard Self.replyHistoryMatches(state: state, identity: identity, account: account,
                    submissionID: submissionID, turnID: turnID) else {
                    return Self.scheduleReplyHistoryRefresh(state: state)
                }
                switch result {
                case .success(let history):
                    return Self.applyHistory(state: &state, cached: false, result: .success(history))
                case .failure(let error):
                    // Keep this pending for a later control/visibility refresh, never a tight loop.
                    state.replyHistoryRefresh?.pending = true
                    state.errorMessage = "保留上次可读历史。" + error.localizedDescription
                    return .none
                }
            case .checkControlReceipt:
                guard let thread = state.activeThread, let attempt = state.controlAttempt,
                      attempt.isUncertain, !state.isSending, let configuration = WorkerConfiguration.load(),
                      MobileSyncCache.shared != nil,
                      state.composerScope == MobileSyncEngine.threadScope(for: thread, configuration: configuration) else { return .none }
                state.isSending = true; state.pendingControlOperation = attempt.operation
                state.pendingControlID = attempt.request.submission_id
                state.isReceiptChecking = true
                Self.invalidateControlRead(state: &state)
                return .concatenate(.cancel(id: CancelID.control), Self.checkControl(thread, attempt: attempt))
            case .clearError:
                state.errorMessage = nil; return .none
            }
        }
    }
    private static func applyHistory(state: inout State, cached: Bool, result: Result<ThreadHistory, CodexError>) -> Effect<Action> {
        if !cached { state.isHistorySyncing = false }
        switch result {
        case .success(let history):
            if !cached { state.errorMessage = nil }
            // An earlier cached read may arrive after a later page was displayed.
            // Compare checkpoints only within one immutable source snapshot.
            if let current = state.history?.pagination, let incoming = history.pagination,
               current.snapshot == incoming.snapshot,
               (current.nextOffset ?? Int.max) > (incoming.nextOffset ?? Int.max) {
                return cached ? .none : Self.scheduleReplyHistoryRefresh(state: state)
            }
            state.history = history; state.lastSyncedAt = history.downloadedAt
            state.messages = history.messages.map {
                ChatMessageAdapter.makeMessage(id: $0.id,
                    sender: $0.role == "user" ? .user : ($0.role == "assistant" ? .assistant : .system),
                    text: $0.text, status: nil, createdAt: $0.sentAt ?? .distantPast)
            }
        case .failure(let error):
            state.errorMessage = "保留上次可读历史。" + error.localizedDescription
        }
        return cached ? .none : Self.scheduleReplyHistoryRefresh(state: state)
    }

    private static func invalidateControlRead(state: inout State) {
        state.isControlLoading = false
        state.isControlPolling = false
        state.controlReadID = nil
    }

    private static func startControlRead(state: inout State, quietly: Bool) -> Effect<Action> {
        guard let thread = state.activeThread else { return .none }
        let readID = UUID().uuidString
        state.controlReadID = readID
        state.isControlLoading = !quietly
        state.isControlPolling = quietly
        return Self.readControl(thread, readID: readID)
            .cancellable(id: CancelID.control, cancelInFlight: true)
    }

    private static func saveDraft(_ draft: ComposerDraft, thread: Thread, scope: String) -> Effect<Action> {
        return .run { _ in try await MobileSyncCache.shared?.saveComposer(draft, threadId: thread.threadId, scope: scope) }
    }
    private static func load(_ thread: Thread, loadID: String, refreshSource: Bool = false) -> Effect<Action> {
        .run { send in
            @Dependency(\.threadSyncClient) var sync
            if let scope = try? MobileSyncEngine.threadScope(for: thread), let cache = MobileSyncCache.shared {
                let draft = (try? await cache.composer(threadId: thread.threadId, scope: scope)) ?? ComposerDraft()
                await send(.composerLoaded(identity: thread.id, scope: scope, loadID: loadID, draft))
            }
            if let history = try? await sync.cachedHistory(thread) {
                try Task.checkCancellation()
                await send(.historyResponse(identity: thread.id, cached: true, .success(history)))
            }
            do {
                let history = try await sync.syncHistory(thread, refreshSource)
                try Task.checkCancellation()
                await send(.historyResponse(identity: thread.id, cached: false, .success(history)))
                try? await sync.markRead(thread.threadId)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await send(.historyResponse(identity: thread.id, cached: false, .failure(CodexError.from(error))))
            }
        }
    }
}
private extension ChatFeature.Action {
    var isExplicitRefresh: Bool { if case .refreshHistory = self { return true }; return false }
}
