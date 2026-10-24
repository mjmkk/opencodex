import ComposableArchitecture
import ExyteChat
import Foundation

@Reducer
public struct ChatFeature {
    private enum CancelID { case history }
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
        public var composerLoadID: String?
        public var controlObservation: NativeControlObservation?
        public var controlAccount: String?
        public var controlObservedAt: Date?
        public var controlAttempt: NativeControlAttempt?
        public var isControlLoading = false
        public var controlMessage: String?
        public var pendingControlOperation: NativeControlOperation?
        public var pendingControlID: String?
        public var controlReadID: String?
        public var isReceiptChecking = false
        public var hasUnconfirmedReply: Bool { outgoing != nil && outgoing?.acknowledgedReceiptID == nil }
        public var hasUncertainControl: Bool { controlAttempt?.isUncertain == true }
        public var canSend: Bool {
            isInputConnected
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
                && controlObservation?.validates(threadID: thread.threadId) == true
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
        case refreshControl, sendReply, stopCurrentTurn, checkControlReceipt
        case controlResponse(identity: String, account: String, readID: String, Result<NativeControlObservation, CodexError>)
        case controlWillWrite(identity: String, account: String, operationID: String, ComposerDraft)
        case controlFinished(identity: String, account: String, operationID: String, Result<ComposerDraft, CodexError>)
        case clearError
    }
    public init() {}
    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear, .onDisappear, .binding:
                return .none
            case .appDidEnterBackground:
                state.isHistorySyncing = false
                return .cancel(id: CancelID.history)
            case .appDidBecomeActive, .refreshHistory:
                guard let thread = state.activeThread else { return .none }
                state.isHistorySyncing = true
                let loadID = UUID().uuidString; state.composerLoadID = loadID
                let refreshSource = action.isExplicitRefresh
                return .merge(Self.load(thread, loadID: loadID, refreshSource: refreshSource)
                    .cancellable(id: CancelID.history, cancelInFlight: true),
                    action.isExplicitRefresh ? .none : .send(.refreshControl))
            case .setActiveThread(let thread):
                if let thread, state.activeThread?.id == thread.id { state.activeThread = thread; return .none }
                state.activeThread = thread; state.messages = []; state.history = nil
                state.inputText = ""; state.outgoing = nil; state.isSending = false
                state.composerScope = nil; state.controlObservation = nil; state.controlAccount = nil
                state.composerTextRevision = nil; state.composerEditedAt = nil
                state.composerLoadID = nil
                state.controlObservedAt = nil; state.controlAttempt = nil; state.controlMessage = nil
                state.isControlLoading = false; state.pendingControlOperation = nil
                state.pendingControlID = nil; state.controlReadID = nil
                state.isReceiptChecking = false
                state.errorMessage = nil; state.lastSyncedAt = nil; state.isHistorySyncing = thread != nil
                guard let thread else { return .cancel(id: CancelID.history) }
                let loadID = UUID().uuidString; state.composerLoadID = loadID
                return .merge(Self.load(thread, loadID: loadID).cancellable(id: CancelID.history, cancelInFlight: true), .send(.refreshControl))
            case .historyResponse(let identity, let cached, let result):
                guard state.activeThread?.id == identity else { return .none }
                if !cached { state.isHistorySyncing = false }
                switch result {
                case .success(let history):
                    if !cached { state.errorMessage = nil }
                    // An earlier cached read may arrive after a later page was displayed.
                    // Compare checkpoints only within one immutable source snapshot.
                    if let current = state.history?.pagination, let incoming = history.pagination,
                       current.snapshot == incoming.snapshot,
                       (current.nextOffset ?? Int.max) > (incoming.nextOffset ?? Int.max) {
                        return .none
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
                return .none
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
                state.inputText = text; state.composerTextRevision = UUID().uuidString; state.composerEditedAt = Date()
                return Self.saveDraft(.init(text: text, outgoing: state.outgoing, controlAttempt: state.controlAttempt,
                    editedAt: state.composerEditedAt, textRevision: state.composerTextRevision), thread: thread, scope: scope)
            case .acknowledgeUnknownReply:
                guard let thread = state.activeThread, state.hasUnconfirmedReply, !state.isSending,
                      let scope = state.currentComposerScope else { return .none }
                state.inputText = state.outgoing?.body ?? state.inputText; state.outgoing = nil
                state.composerTextRevision = UUID().uuidString; state.composerEditedAt = Date()
                return Self.saveDraft(.init(text: state.inputText, controlAttempt: state.controlAttempt,
                    editedAt: state.composerEditedAt, textRevision: state.composerTextRevision), thread: thread, scope: scope)
            case .didSendDraft(let draft):
                return Self.beginControl(state: &state, operation: .input, text: draft.text)
            case .sendReply:
                let text = state.inputText
                return Self.beginControl(state: &state, operation: .input, text: text)
            case .stopCurrentTurn:
                let text = state.inputText
                return Self.beginControl(state: &state, operation: .interrupt, text: text)
            case .refreshControl:
                guard let thread = state.activeThread, !state.isControlLoading else { return .none }
                state.isControlLoading = true
                let readID = UUID().uuidString; state.controlReadID = readID
                return Self.readControl(thread, readID: readID)
            case .controlResponse(let identity, let account, let readID, let result):
                guard state.activeThread?.id == identity, state.controlReadID == readID else { return .none }
                state.isControlLoading = false
                guard (try? MobileSyncEngine.scope()) == account else { state.controlObservation = nil; return .none }
                state.controlAccount = account
                switch result {
                case .success(let observation):
                    state.controlObservation = observation; state.controlObservedAt = Date()
                    state.controlMessage = nil
                case .failure:
                    state.controlObservation = nil; state.controlMessage = "暂时无法核对执行状态，草稿会保留。"
                }
                return .none
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
                       state.inputText == attempt.request.text {
                        state.inputText = draft.text; state.composerTextRevision = draft.textRevision
                        state.composerEditedAt = draft.editedAt
                    }
                    state.controlAttempt = draft.controlAttempt
                    state.controlMessage = nil
                case .failure:
                    state.controlMessage = state.controlAttempt?.isUncertain == false ? nil
                        : "操作尚未完成，草稿和提交记录会保留。"
                }
                return .send(.refreshControl)
            case .checkControlReceipt:
                guard let thread = state.activeThread, let attempt = state.controlAttempt,
                      attempt.isUncertain, !state.isSending, let configuration = WorkerConfiguration.load(),
                      MobileSyncCache.shared != nil,
                      state.composerScope == MobileSyncEngine.threadScope(for: thread, configuration: configuration) else { return .none }
                state.isSending = true; state.pendingControlOperation = attempt.operation
                state.pendingControlID = attempt.request.submission_id
                state.isReceiptChecking = true
                return Self.checkControl(thread, attempt: attempt)
            case .clearError:
                state.errorMessage = nil; return .none
            }
        }
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
