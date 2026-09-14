import ComposableArchitecture
import Foundation

@Reducer
public struct MobileInboxFeature {
    private enum CancelID: Hashable { case load; case draft(String); case submit }
    @ObservableState
    public struct State: Equatable {
        public var items: [MobileApproval] = []
        public var drafts: [String: MobileApprovalDraft] = [:]
        public var selected: Set<String> = []
        public var viewed: Set<String> = []
        public var isLoading = false
        public var isSubmitting = false
        public var message: String?
        public var accountScope: String?
        public init() {}
        public var batchScope: String? {
            let items = items.filter { selected.contains($0.id) }
            guard items.count > 1, let first = items.first, let scope = first.batchScope, !scope.isEmpty,
                  items.allSatisfy({ $0.state == "pending" && !$0.expired && $0.batchScope == scope &&
                      $0.request["context_version"] == first.request["context_version"] &&
                      $0.request["return_target"] == first.request["return_target"] && drafts[$0.id]?.requestVersion == $0.request_version }) else { return nil }
            return scope
        }
    }
    public enum Action {
        case load
        case cached([MobileApproval], [String: MobileApprovalDraft], String)
        case loaded(Result<MobileApprovalList, CodexError>)
        case edit(String, JSONValue)
        case view(String)
        case select(String, Bool)
        case submit([String], String?)
        case submitted(Result<MobileApprovalList, CodexError>)
        case dismiss
    }
    public init() {}
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .load:
                state.isLoading = true
                return .run { send in
                    @Dependency(\.apiClient) var api
                    do {
                        let scope = try MobileSyncEngine.scope()
                        let (items, drafts) = try await MobileApprovalStore.cached()
                        await send(.cached(items, drafts, scope))
                        let response = try await api.mobileApprovals()
                        guard try MobileSyncEngine.scope() == scope else { return }
                        try await MobileApprovalStore.save(response.data)
                        await send(.loaded(.success(response)))
                    } catch { await send(.loaded(.failure(CodexError.from(error)))) }
                }.cancellable(id: CancelID.load, cancelInFlight: true)
            case .cached(let items, let drafts, let scope):
                state.items = items; state.drafts = drafts; state.accountScope = scope
                return .none
            case .loaded(.success(let response)):
                state.items = response.data; state.isLoading = false; state.message = nil
                return .none
            case .loaded(.failure(let error)):
                state.isLoading = false; state.message = "保留本地内容，尚未同步：" + error.localizedDescription
                return .none
            case .edit(let id, let value):
                guard !state.isSubmitting, let item = state.items.first(where: { $0.id == id }), item.state == "pending" else { return .none }
                let draft = MobileApprovalDraft(requestVersion: item.request_version, eventId: UUID().uuidString, value: value)
                state.drafts[id] = draft
                let scope = state.accountScope
                return .run { _ in
                    @Dependency(\.continuousClock) var clock
                    try await clock.sleep(for: .milliseconds(100))
                    guard try MobileSyncEngine.scope() == scope else { return }
                    try await MobileApprovalStore.saveDraft(draft, id: id)
                }.cancellable(id: CancelID.draft(id), cancelInFlight: true)
            case .view(let id):
                guard state.viewed.insert(id).inserted else { return .none }
                return .run { _ in
                    @Dependency(\.apiClient) var api
                    try? await api.viewMobileApproval(id)
                }
            case .select(let id, let selected):
                if selected { state.selected.insert(id) } else { state.selected.remove(id) }
                return .none
            case .submit(let ids, let scope):
                guard !state.isSubmitting, !ids.isEmpty, ids.count == 1 || state.batchScope == scope && scope != nil else { return .none }
                let drafts = state.drafts
                let answers = ids.compactMap { id -> MobileApprovalSubmission? in
                    guard let item = state.items.first(where: { $0.id == id }), item.state == "pending", !item.expired,
                          let draft = drafts[id], draft.requestVersion == item.request_version else { return nil }
                    return .init(id: id, request_version: draft.requestVersion, event_id: draft.eventId, value: draft.value)
                }
                guard answers.count == ids.count else { state.message = "请填写当前请求；过期内容不能提交。"; return .none }
                state.isSubmitting = true; state.message = nil
                let account = state.accountScope
                return .run { send in
                    @Dependency(\.apiClient) var api
                    do {
                        guard try MobileSyncEngine.scope() == account else { throw CodexError.invalidState }
                        for id in ids { if let draft = drafts[id] { try await MobileApprovalStore.saveDraft(draft, id: id) } }
                        let result = try await api.submitMobileApprovals(answers, scope)
                        guard try MobileSyncEngine.scope() == account else { throw CodexError.invalidState }
                        try await MobileApprovalStore.save(result.data)
                        await send(.submitted(.success(result)))
                    } catch { await send(.submitted(.failure(CodexError.from(error)))) }
                }.cancellable(id: CancelID.submit)
            case .submitted(.success(let response)):
                state.isSubmitting = false; state.message = "服务端已确认接收。回传状态见每条请求。"
                for item in response.data {
                    if let i = state.items.firstIndex(where: { $0.id == item.id }) { state.items[i] = item }
                    state.selected.remove(item.id)
                }
                return .none
            case .submitted(.failure(let error)):
                state.isSubmitting = false
                state.message = "尚未确认提交，草稿已保留；请刷新核对后再操作。" + error.localizedDescription
                return .none
            case .dismiss:
                return .cancel(id: CancelID.load)
            }
        }
    }
}
