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
        public var hasUnconfirmedReply: Bool { outgoing != nil && outgoing?.acknowledgedReceiptID == nil }
        // Enabled only when the current native adapter supplies a verified reply capability.
        // There is deliberately no fallback to the retired job/turn writer.
        public var canSend: Bool { false }
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
        case composerLoaded(identity: String, ComposerDraft)
        case acknowledgeUnknownReply
        case didSendDraft(DraftMessage)
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
                let refreshSource = action.isExplicitRefresh
                return Self.load(thread, refreshSource: refreshSource)
                    .cancellable(id: CancelID.history, cancelInFlight: true)
            case .setActiveThread(let thread):
                if let thread, state.activeThread?.id == thread.id { state.activeThread = thread; return .none }
                state.activeThread = thread; state.messages = []; state.history = nil
                state.inputText = ""; state.outgoing = nil; state.isSending = false
                state.errorMessage = nil; state.lastSyncedAt = nil; state.isHistorySyncing = thread != nil
                guard let thread else { return .cancel(id: CancelID.history) }
                return Self.load(thread).cancellable(id: CancelID.history, cancelInFlight: true)
            case .historyResponse(let identity, let cached, let result):
                guard state.activeThread?.id == identity else { return .none }
                if !cached { state.isHistorySyncing = false }
                switch result {
                case .success(let history):
                    state.history = history; state.lastSyncedAt = history.downloadedAt
                    state.messages = history.messages.map {
                        ChatMessageAdapter.makeMessage(id: $0.id,
                            sender: $0.role == "user" ? .user : ($0.role == "assistant" ? .assistant : .system),
                            text: $0.text, createdAt: $0.sentAt ?? .distantPast)
                    }
                    if !cached { state.errorMessage = nil }
                case .failure(let error):
                    state.errorMessage = "保留上次可读历史。" + error.localizedDescription
                }
                return .none
            case .syncMetadata(let id, let metadata):
                guard state.activeThread?.threadId == id else { return .none }
                state.lastSyncedAt = metadata?.lastSyncedAt
                return .none
            case .composerLoaded(let identity, let draft):
                guard state.activeThread?.id == identity, state.inputText.isEmpty, !state.isSending else { return .none }
                state.inputText = draft.text; state.outgoing = draft.outgoing
                return .none
            case .composerChanged(let id, let text):
                guard let thread = state.activeThread, thread.threadId == id, !state.isSending,
                      !state.hasUnconfirmedReply, state.inputText != text else { return .none }
                state.inputText = text
                return Self.saveDraft(.init(text: text, outgoing: state.outgoing), thread: thread)
            case .acknowledgeUnknownReply:
                guard let thread = state.activeThread, state.hasUnconfirmedReply, !state.isSending else { return .none }
                state.inputText = state.outgoing?.body ?? state.inputText; state.outgoing = nil
                return Self.saveDraft(.init(text: state.inputText), thread: thread)
            case .didSendDraft:
                state.errorMessage = "当前回复入口尚未可用，草稿已保留。请在原任务继续。"
                return .none
            case .clearError:
                state.errorMessage = nil; return .none
            }
        }
    }
    private static func saveDraft(_ draft: ComposerDraft, thread: Thread) -> Effect<Action> {
        guard let scope = try? MobileSyncEngine.threadScope(for: thread) else { return .none }
        return .run { _ in try await MobileSyncCache.shared?.saveComposer(draft, threadId: thread.threadId, scope: scope) }
    }
    private static func load(_ thread: Thread, refreshSource: Bool = false) -> Effect<Action> {
        .run { send in
            @Dependency(\.threadSyncClient) var sync
            if let scope = try? MobileSyncEngine.threadScope(for: thread),
               let draft = try? await MobileSyncCache.shared?.composer(threadId: thread.threadId, scope: scope) {
                await send(.composerLoaded(identity: thread.id, draft))
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
