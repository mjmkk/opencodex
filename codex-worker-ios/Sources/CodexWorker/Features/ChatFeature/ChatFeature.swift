//
//  ChatFeature.swift
//  CodexWorker
//
//  聊天 Feature（里程碑 3）
//

import ComposableArchitecture
import ExyteChat
import Foundation

@Reducer
public struct ChatFeature {
    private enum CancelID {
        case sseStream
    }

    @ObservableState
    public struct State: Equatable {
        public var activeThread: Thread?
        public var currentJobId: String?
        public var cursor: Int = -1
        public var messages: [Message] = []
        public var pendingAssistantDeltas: [String: MessageDelta] = [:]
        public var inputText = ""
        public var isSending = false
        public var isStreaming = false
        public var isApprovalLocked = false
        public var errorMessage: String?
        public var jobState: JobState?

        public var canSend: Bool {
            activeThread != nil && !isSending && !isApprovalLocked
        }

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case onDisappear
        case setActiveThread(Thread?)
        case didSendDraft(DraftMessage)
        case startTurnResponse(Result<StartTurnResponse, CodexError>)
        case startStreaming(jobId: String, cursor: Int)
        case stopStreaming
        case streamEventReceived(EventEnvelope)
        case streamFailed(CodexError)
        case clearError
        case setApprovalLocked(Bool)
        case delegate(Delegate)
    }

    public enum Delegate {
        case approvalRequired(Approval)
        case approvalResolved(approvalId: String, decision: String?)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .none

            case .onDisappear:
                state.isStreaming = false
                return .merge(
                    .run { _ in
                        @Dependency(\.sseClient) var sseClient
                        sseClient.cancel()
                    },
                    .cancel(id: CancelID.sseStream)
                )

            case .setActiveThread(let thread):
                // 切线程时重置聊天上下文，避免串流状态污染
                state.activeThread = thread
                state.currentJobId = nil
                state.cursor = -1
                state.messages = []
                state.pendingAssistantDeltas.removeAll()
                state.isSending = false
                state.isStreaming = false
                state.isApprovalLocked = false
                state.errorMessage = nil
                state.jobState = nil
                return .merge(
                    .run { _ in
                        @Dependency(\.sseClient) var sseClient
                        sseClient.cancel()
                    },
                    .cancel(id: CancelID.sseStream)
                )

            case .didSendDraft(let draft):
                guard state.canSend else { return .none }
                let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let threadId = state.activeThread?.threadId else { return .none }

                // 先本地回显用户消息，提升交互反馈
                let localUserMessage = ChatMessageAdapter.makeMessage(
                    id: "local-user-\(UUID().uuidString)",
                    sender: .user,
                    text: text,
                    createdAt: draft.createdAt
                )
                state.messages.append(localUserMessage)
                state.isSending = true
                state.errorMessage = nil

                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    let request = StartTurnRequest(
                        text: text,
                        input: nil,
                        approvalPolicy: nil
                    )
                    await send(
                        .startTurnResponse(
                            Result {
                                try await apiClient.startTurn(threadId, request)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .startTurnResponse(.success(let response)):
                state.isSending = false
                state.currentJobId = response.jobId
                state.cursor = -1
                state.jobState = .running
                return .send(.startStreaming(jobId: response.jobId, cursor: state.cursor))

            case .startTurnResponse(.failure(let error)):
                state.isSending = false
                state.errorMessage = error.localizedDescription
                return .none

            case .startStreaming(let jobId, let cursor):
                state.isStreaming = true
                return .run { send in
                    @Dependency(\.sseClient) var sseClient
                    do {
                        let stream = try await sseClient.subscribe(jobId, cursor)
                        for await envelope in stream {
                            await send(.streamEventReceived(envelope))
                        }
                    } catch {
                        await send(.streamFailed(CodexError.from(error)))
                    }
                }
                .cancellable(id: CancelID.sseStream, cancelInFlight: true)

            case .stopStreaming:
                state.isStreaming = false
                return .merge(
                    .run { _ in
                        @Dependency(\.sseClient) var sseClient
                        sseClient.cancel()
                    },
                    .cancel(id: CancelID.sseStream)
                )

            case .streamEventReceived(let envelope):
                state.cursor = max(state.cursor, envelope.seq)
                return self.handleStreamEvent(state: &state, envelope: envelope)

            case .streamFailed(let error):
                state.isStreaming = false
                state.errorMessage = error.localizedDescription
                return .none

            case .clearError:
                state.errorMessage = nil
                return .none

            case .setApprovalLocked(let locked):
                state.isApprovalLocked = locked
                return .none

            case .delegate:
                return .none

            case .binding:
                return .none
            }
        }
    }

    /// 统一处理 SSE 事件
    private func handleStreamEvent(state: inout State, envelope: EventEnvelope) -> Effect<Action> {
        switch envelope.eventType {
        case .jobState:
            if let raw = envelope.payload?["state"]?.stringValue, let mapped = JobState(rawValue: raw) {
                state.jobState = mapped
                if mapped != .waitingApproval {
                    state.isApprovalLocked = false
                }
            }
            return .none

        case .approvalRequired:
            guard
                let payload = envelope.payload,
                let approval = Approval.fromPayload(payload, fallbackJobId: envelope.jobId)
            else {
                return .none
            }
            state.jobState = .waitingApproval
            state.isApprovalLocked = true
            return .send(.delegate(.approvalRequired(approval)))

        case .approvalResolved:
            let approvalId = envelope.payload?["approvalId"]?.stringValue ?? ""
            let decision = envelope.payload?["decision"]?.stringValue
            state.isApprovalLocked = false
            return .send(.delegate(.approvalResolved(approvalId: approvalId, decision: decision)))

        case .itemAgentMessageDelta:
            guard let payload = envelope.payload else { return .none }
            let itemId = payload["itemId"]?.stringValue ?? "assistant-\(envelope.seq)"
            let delta = payload["delta"]?.stringValue
                ?? payload["textDelta"]?.stringValue
                ?? payload["text"]?.stringValue
                ?? ""
            guard !delta.isEmpty else { return .none }
            if var existing = state.pendingAssistantDeltas[itemId] {
                existing.append(delta)
                state.pendingAssistantDeltas[itemId] = existing
                upsertMessage(&state.messages, with: existing.toMessage())
            } else {
                var newDelta = MessageDelta(id: itemId, text: "", sender: .assistant)
                newDelta.append(delta)
                state.pendingAssistantDeltas[itemId] = newDelta
                upsertMessage(&state.messages, with: newDelta.toMessage())
            }
            return .none

        case .itemCompleted:
            if let payload = envelope.payload {
                let itemId =
                    payload["itemId"]?.stringValue
                    ?? payload["item"]?.objectValue?["id"]?.stringValue
                if let itemId, var delta = state.pendingAssistantDeltas[itemId] {
                    delta.markComplete()
                    state.pendingAssistantDeltas[itemId] = nil
                    upsertMessage(&state.messages, with: delta.toMessage())
                }
            }
            return .none

        case .jobFinished:
            if let raw = envelope.payload?["state"]?.stringValue, let mapped = JobState(rawValue: raw) {
                state.jobState = mapped
            }
            return .send(.stopStreaming)

        case .error:
            let msg = envelope.payload?["message"]?.stringValue ?? "SSE 出现错误"
            state.errorMessage = msg
            return .none

        default:
            return .none
        }
    }

    /// 按消息 id 更新或插入，避免重复气泡
    private func upsertMessage(_ messages: inout [Message], with message: Message) {
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = message
        } else {
            messages.append(message)
        }
    }
}
