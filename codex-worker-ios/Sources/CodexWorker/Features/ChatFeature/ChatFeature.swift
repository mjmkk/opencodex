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
        case threadHistoryLoad
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
        case threadHistoryCacheResponse(threadId: String, Result<[EventEnvelope], CodexError>)
        case threadHistorySyncResponse(threadId: String, Result<[EventEnvelope], CodexError>)
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
                let cancelEffect: Effect<Action> = .merge(
                    .run { _ in
                        @Dependency(\.sseClient) var sseClient
                        sseClient.cancel()
                    },
                    .cancel(id: CancelID.sseStream),
                    .cancel(id: CancelID.threadHistoryLoad)
                )
                guard let thread else { return cancelEffect }
                return .merge(
                    cancelEffect,
                    .run { send in
                        @Dependency(\.apiClient) var apiClient
                        @Dependency(\.threadHistoryStore) var threadHistoryStore

                        // 第一步：先读本地缓存，保证切线程秒开。
                        await send(
                            .threadHistoryCacheResponse(
                                threadId: thread.threadId,
                                Result {
                                    try await threadHistoryStore.loadCachedEvents(thread.threadId)
                                }.mapError { CodexError.from($0) }
                            )
                        )

                        // 第二步：远端按 cursor 增量同步并落库，再刷新 UI。
                        await send(
                            .threadHistorySyncResponse(
                                threadId: thread.threadId,
                                Result {
                                    try await Self.syncThreadHistory(
                                        threadId: thread.threadId,
                                        apiClient: apiClient,
                                        threadHistoryStore: threadHistoryStore
                                    )
                                }.mapError { CodexError.from($0) }
                            )
                        )
                    }
                )
                .cancellable(id: CancelID.threadHistoryLoad, cancelInFlight: true)

            case .threadHistoryCacheResponse(let threadId, .success(let events)):
                guard state.activeThread?.threadId == threadId else { return .none }
                return applyThreadReplay(state: &state, events: events)

            case .threadHistoryCacheResponse(let threadId, .failure(let error)):
                guard state.activeThread?.threadId == threadId else { return .none }
                state.errorMessage = "读取本地缓存失败：\(error.localizedDescription)"
                return .none

            case .threadHistorySyncResponse(let threadId, .success(let events)):
                guard state.activeThread?.threadId == threadId else { return .none }
                return applyThreadReplay(state: &state, events: events)

            case .threadHistorySyncResponse(let threadId, .failure(let error)):
                guard state.activeThread?.threadId == threadId else { return .none }
                state.errorMessage = error.localizedDescription
                return .none

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
                guard state.currentJobId == nil || envelope.jobId == state.currentJobId else {
                    return .none
                }
                state.cursor = max(state.cursor, envelope.seq)
                let uiEffect = self.handleStreamEvent(state: &state, envelope: envelope)
                guard let threadId = state.activeThread?.threadId else {
                    return uiEffect
                }
                return .merge(
                    uiEffect,
                    .run { _ in
                        @Dependency(\.threadHistoryStore) var threadHistoryStore
                        do {
                            try await threadHistoryStore.appendLiveEvent(threadId, envelope)
                        } catch {
                            // 本地缓存失败不应影响主链路（消息流展示优先）。
                        }
                    }
                )

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
            let approvalId =
                envelope.payload?["approvalId"]?.stringValue
                ?? envelope.payload?["approval_id"]?.stringValue
                ?? ""
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

    /// 应用线程历史回放结果到当前状态
    private func applyThreadReplay(state: inout State, events: [EventEnvelope]) -> Effect<Action> {
        let replay = replayThreadEvents(events)
        state.messages = replay.messages
        state.pendingAssistantDeltas = replay.pendingAssistantDeltas
        state.currentJobId = replay.currentJobId
        state.cursor = replay.cursor
        state.jobState = replay.jobState
        state.isApprovalLocked = replay.isApprovalLocked
        state.errorMessage = replay.errorMessage

        if events.isEmpty,
           state.messages.isEmpty,
           let thread = state.activeThread
        {
            let preview = thread.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !preview.isEmpty {
                state.messages = [
                    ChatMessageAdapter.makeMessage(
                        id: "thread-preview-\(thread.threadId)",
                        sender: .system,
                        text: "该线程暂无可回放历史，先展示预览：\n\(preview)"
                    ),
                ]
            }
        }

        guard
            let activeJobId = replay.currentJobId,
            let activeState = replay.jobState,
            activeState.isActive
        else {
            return .none
        }
        return .send(.startStreaming(jobId: activeJobId, cursor: replay.cursor))
    }

    /// 基于线程游标执行远端增量同步
    private static func syncThreadHistory(
        threadId: String,
        apiClient: APIClient,
        threadHistoryStore: ThreadHistoryStore
    ) async throws -> [EventEnvelope] {
        var cursor = try await threadHistoryStore.loadCursor(threadId)
        var syncedEvents = try await threadHistoryStore.loadCachedEvents(threadId)
        var hasResetOnce = false

        while true {
            do {
                let page = try await apiClient.listThreadEvents(threadId, cursor, 200)
                if page.hasMore, page.nextCursor <= cursor {
                    throw CodexError.invalidState
                }
                syncedEvents = try await threadHistoryStore.mergeRemotePage(threadId, cursor, page)
                cursor = page.nextCursor
                if !page.hasMore {
                    return syncedEvents
                }
            } catch let error as CodexError where error == .cursorExpired {
                if hasResetOnce {
                    throw error
                }
                hasResetOnce = true
                try await threadHistoryStore.resetThread(threadId)
                cursor = -1
                syncedEvents = []
            }
        }
    }

    /// 将线程历史事件回放为聊天状态
    private func replayThreadEvents(_ events: [EventEnvelope]) -> ThreadHistoryReplay {
        var replay = ThreadHistoryReplay()
        var lastSeqByJob: [String: Int] = [:]

        for envelope in events {
            replay.currentJobId = envelope.jobId
            lastSeqByJob[envelope.jobId] = max(lastSeqByJob[envelope.jobId] ?? -1, envelope.seq)

            switch envelope.eventType {
            case .jobState:
                if let raw = envelope.payload?["state"]?.stringValue, let mapped = JobState(rawValue: raw) {
                    replay.jobState = mapped
                    if mapped != .waitingApproval {
                        replay.isApprovalLocked = false
                    }
                }

            case .approvalRequired:
                replay.jobState = .waitingApproval
                replay.isApprovalLocked = true

            case .approvalResolved:
                replay.isApprovalLocked = false

            case .itemStarted, .itemCompleted:
                if let userMessage = userMessage(from: envelope) {
                    upsertMessage(&replay.messages, with: userMessage)
                }
                handleAssistantCompletionIfNeeded(replay: &replay, envelope: envelope)

            case .itemAgentMessageDelta:
                guard let payload = envelope.payload else { continue }
                let itemId = payload["itemId"]?.stringValue ?? "assistant-\(envelope.jobId)-\(envelope.seq)"
                let delta = payload["delta"]?.stringValue
                    ?? payload["textDelta"]?.stringValue
                    ?? payload["text"]?.stringValue
                    ?? ""
                guard !delta.isEmpty else { continue }

                if var existing = replay.pendingAssistantDeltas[itemId] {
                    existing.append(delta)
                    replay.pendingAssistantDeltas[itemId] = existing
                    upsertMessage(&replay.messages, with: existing.toMessage())
                } else {
                    var newDelta = MessageDelta(id: itemId, text: "", sender: .assistant)
                    newDelta.append(delta)
                    replay.pendingAssistantDeltas[itemId] = newDelta
                    upsertMessage(&replay.messages, with: newDelta.toMessage())
                }

            case .jobFinished:
                if let raw = envelope.payload?["state"]?.stringValue, let mapped = JobState(rawValue: raw) {
                    replay.jobState = mapped
                }

            case .error:
                replay.errorMessage = envelope.payload?["message"]?.stringValue ?? replay.errorMessage

            default:
                continue
            }
        }

        if replay.jobState?.isActive != true {
            replay.isApprovalLocked = false
        }
        replay.cursor = replay.currentJobId.flatMap { lastSeqByJob[$0] } ?? -1
        return replay
    }

    /// 从 item.started / item.completed 中提取用户消息
    private func userMessage(from envelope: EventEnvelope) -> Message? {
        guard
            let payload = envelope.payload,
            let item = payload["item"]?.objectValue,
            item["type"]?.stringValue == "userMessage",
            let itemId = item["id"]?.stringValue
        else {
            return nil
        }

        var fragments: [String] = []
        if let content = item["content"]?.arrayValue {
            for entry in content {
                guard let object = entry.objectValue else { continue }
                if let text = object["text"]?.stringValue, !text.isEmpty {
                    fragments.append(text)
                }
            }
        }

        let fallbackText = item["text"]?.stringValue ?? payload["text"]?.stringValue
        let text = fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = text.isEmpty ? fallbackText ?? "" : text
        guard !finalText.isEmpty else { return nil }

        return ChatMessageAdapter.makeMessage(
            id: itemId,
            sender: .user,
            text: finalText,
            createdAt: envelope.timestamp ?? Date()
        )
    }

    /// 在 item.completed 时收敛助手消息，兜底处理无 delta 的场景
    private func handleAssistantCompletionIfNeeded(
        replay: inout ThreadHistoryReplay,
        envelope: EventEnvelope
    ) {
        guard
            envelope.eventType == .itemCompleted,
            let payload = envelope.payload,
            let item = payload["item"]?.objectValue,
            item["type"]?.stringValue == "agentMessage",
            let itemId = item["id"]?.stringValue
        else {
            return
        }

        if var delta = replay.pendingAssistantDeltas[itemId] {
            delta.markComplete()
            replay.pendingAssistantDeltas[itemId] = nil
            upsertMessage(&replay.messages, with: delta.toMessage())
            return
        }

        // 某些历史数据只保留 completed 文本，不含 delta，需兜底展示。
        if let fullText = item["text"]?.stringValue, !fullText.isEmpty {
            let message = ChatMessageAdapter.makeMessage(
                id: itemId,
                sender: .assistant,
                text: fullText,
                createdAt: envelope.timestamp ?? Date()
            )
            upsertMessage(&replay.messages, with: message)
        }
    }
}

private struct ThreadHistoryReplay: Sendable {
    var currentJobId: String?
    var cursor: Int = -1
    var messages: [Message] = []
    var pendingAssistantDeltas: [String: MessageDelta] = [:]
    var jobState: JobState?
    var isApprovalLocked = false
    var errorMessage: String?
}
