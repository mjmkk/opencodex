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
    private static let threadHistoryPageLimit = 1000
    private static let streamBatchSize = 24
    private static let streamBatchMaxDelay: Duration = .milliseconds(80)

    private struct ThreadHistorySyncOutcome: Sendable {
        let events: [EventEnvelope]
        let shouldApply: Bool
    }

    @ObservableState
    public struct State: Equatable {
        public var activeThread: Thread?
        public var currentJobId: String?
        public var cursor: Int = -1
        public var messages: [Message] = []
        public var pendingAssistantDeltas: [String: MessageDelta] = [:]
        public var pendingLocalUserMessageId: String?
        public var inputText = ""
        public var isSending = false
        public var isStreaming = false
        public var streamConnectionState: StreamConnectionState = .idle
        public var isApprovalLocked = false
        public var pendingApprovalsById: [String: Approval] = [:]
        public var approvalOrder: [String] = []
        public var errorMessage: String?
        public var jobState: JobState?

        public var canSend: Bool {
            activeThread != nil && !isSending && !isApprovalLocked
        }

        public var shouldShowGeneratingIndicator: Bool {
            isStreaming && (jobState?.isActive ?? false) && !isApprovalLocked
        }

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case onDisappear
        case appDidBecomeActive
        case appDidEnterBackground
        case setActiveThread(Thread?)
        case threadHistoryCacheResponse(threadId: String, Result<[EventEnvelope], CodexError>)
        case threadHistorySyncResponse(threadId: String, Result<[EventEnvelope], CodexError>)
        case threadHistorySyncNoChange(threadId: String)
        case didSendDraft(DraftMessage)
        case startTurnResponse(localMessageId: String, Result<StartTurnResponse, CodexError>)
        case startStreaming(jobId: String, cursor: Int)
        case stopStreaming
        case streamEventReceived(EventEnvelope)
        case streamEventsReceived([EventEnvelope])
        case streamFailed(CodexError)
        case clearError
        case setApprovalLocked(Bool)
        case delegate(Delegate)
    }

    public enum Delegate {
        case approvalRequired(Approval)
        case approvalResolved(approvalId: String, decision: String?)
        case streamConnectionChanged(StreamConnectionState)
        case jobFinished(state: JobState, jobId: String)
    }

    public enum StreamConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed(String)
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
                state.pendingLocalUserMessageId = nil
                let streamStateEffect = updateStreamConnectionState(
                    state: &state,
                    newValue: .idle
                )
                return .merge(
                    streamStateEffect,
                    .run { _ in
                        @Dependency(\.sseClient) var sseClient
                        sseClient.cancel()
                    },
                    .cancel(id: CancelID.sseStream)
                )

            case .appDidBecomeActive:
                guard let threadId = state.activeThread?.threadId else { return .none }
                let shouldPreemptStream = state.isStreaming || state.streamConnectionState != .idle
                let refreshEffect = Self.refreshThreadHistoryFromRemote(threadId: threadId)
                    .cancellable(id: CancelID.threadHistoryLoad, cancelInFlight: true)
                if shouldPreemptStream {
                    return .concatenate(.send(.stopStreaming), refreshEffect)
                }
                return refreshEffect

            case .appDidEnterBackground:
                if state.isStreaming || state.streamConnectionState != .idle {
                    return .send(.stopStreaming)
                }
                return .none

            case .setActiveThread(let thread):
                // 切线程时重置聊天上下文，避免串流状态污染
                state.activeThread = thread
                state.currentJobId = nil
                state.cursor = -1
                state.messages = []
                state.pendingAssistantDeltas.removeAll()
                state.pendingLocalUserMessageId = nil
                state.isSending = false
                state.isStreaming = false
                state.isApprovalLocked = false
                state.pendingApprovalsById.removeAll()
                state.approvalOrder.removeAll()
                state.errorMessage = nil
                state.jobState = nil
                let streamStateEffect = updateStreamConnectionState(
                    state: &state,
                    newValue: .idle
                )
                let cancelEffect: Effect<Action> = .merge(
                    streamStateEffect,
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
                        do {
                            let syncResult = try await Self.syncThreadHistory(
                                threadId: thread.threadId,
                                apiClient: apiClient,
                                threadHistoryStore: threadHistoryStore
                            )
                            if syncResult.shouldApply {
                                await send(.threadHistorySyncResponse(threadId: thread.threadId, .success(syncResult.events)))
                            } else {
                                await send(.threadHistorySyncNoChange(threadId: thread.threadId))
                            }
                        } catch {
                            await send(
                                .threadHistorySyncResponse(
                                    threadId: thread.threadId,
                                    .failure(CodexError.from(error))
                                )
                            )
                        }
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

            case .threadHistorySyncNoChange(let threadId):
                guard state.activeThread?.threadId == threadId else { return .none }
                if shouldResumeStreamingAfterSync(state: state),
                   let activeJobId = state.currentJobId
                {
                    return .send(.startStreaming(jobId: activeJobId, cursor: state.cursor))
                }
                return .none

            case .didSendDraft(let draft):
                guard state.canSend else { return .none }
                let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let threadId = state.activeThread?.threadId else { return .none }
                let localMessageId = "local-user-\(UUID().uuidString)"

                // 先本地回显用户消息，提升交互反馈
                let localUserMessage = ChatMessageAdapter.makeMessage(
                    id: localMessageId,
                    sender: .user,
                    text: text,
                    status: .sending,
                    createdAt: draft.createdAt
                )
                state.messages.append(localUserMessage)
                state.pendingLocalUserMessageId = localMessageId
                state.isSending = true
                state.errorMessage = nil

                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    @Dependency(\.executionAccessStore) var executionAccessStore
                    @Dependency(\.workerConfigurationStore) var workerConfigurationStore
                    let mode = executionAccessStore.load()
                    let settings = mode.turnRequestSettings
                    let preferredModel = workerConfigurationStore.load()?.model
                    let request = StartTurnRequest(
                        text: text,
                        input: nil,
                        approvalPolicy: settings.approvalPolicy,
                        sandbox: settings.sandbox,
                        model: preferredModel
                    )
                    await send(
                        .startTurnResponse(
                            localMessageId: localMessageId,
                            Result {
                                try await apiClient.startTurn(threadId, request)
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .startTurnResponse(let localMessageId, .success(let response)):
                state.isSending = false
                state.currentJobId = response.jobId
                state.cursor = -1
                state.jobState = .running
                markMessageStatus(state: &state, messageId: localMessageId, status: .sent)
                state.pendingLocalUserMessageId = nil
                return .send(.startStreaming(jobId: response.jobId, cursor: state.cursor))

            case .startTurnResponse(let localMessageId, .failure(let error)):
                state.isSending = false
                state.errorMessage = error.localizedDescription
                markMessageStatus(
                    state: &state,
                    messageId: localMessageId,
                    status: .error(
                        DraftMessage(
                            id: localMessageId,
                            text: messageText(in: state.messages, messageId: localMessageId),
                            medias: [],
                            giphyMedia: nil,
                            recording: nil,
                            replyMessage: nil,
                            createdAt: Date()
                        )
                    )
                )
                state.pendingLocalUserMessageId = nil
                return .none

            case .startStreaming(let jobId, let cursor):
                state.isStreaming = true
                let streamStateEffect = updateStreamConnectionState(
                    state: &state,
                    newValue: .connecting
                )
                return .merge(
                    streamStateEffect,
                    .run { send in
                        @Dependency(\.apiClient) var apiClient
                        @Dependency(\.sseClient) var sseClient
                        do {
                            // 先走一次 JSON 拉取做“断线恢复”，避免直接 SSE 遇到 cursor 过期。
                            // 如果游标过期，回退到无 cursor 全量窗口，并让 UI 通过事件回放恢复审批状态。
                            let bootstrapPage: EventsListResponse
                            do {
                                bootstrapPage = try await apiClient.listEvents(jobId, cursor)
                            } catch let error as CodexError where error == .cursorExpired {
                                bootstrapPage = try await apiClient.listEvents(jobId, nil)
                            }

                            if !bootstrapPage.data.isEmpty {
                                await Self.sendEventsInBatches(
                                    bootstrapPage.data,
                                    send: send
                                )
                            }
                            if Task.isCancelled {
                                return
                            }

                            let stream = try await sseClient.subscribe(jobId, bootstrapPage.nextCursor)
                            await Self.forwardStreamEvents(stream, send: send)
                        } catch is CancellationError {
                            return
                        } catch {
                            await send(.streamFailed(CodexError.from(error)))
                        }
                    }
                    .cancellable(id: CancelID.sseStream, cancelInFlight: true)
                )

            case .stopStreaming:
                state.isStreaming = false
                let streamStateEffect = updateStreamConnectionState(
                    state: &state,
                    newValue: .idle
                )
                return .merge(
                    streamStateEffect,
                    .run { _ in
                        @Dependency(\.sseClient) var sseClient
                        sseClient.cancel()
                    },
                    .cancel(id: CancelID.sseStream)
                )

            case .streamEventReceived(let envelope):
                return handleStreamEnvelopes(state: &state, envelopes: [envelope])

            case .streamEventsReceived(let envelopes):
                return handleStreamEnvelopes(state: &state, envelopes: envelopes)

            case .streamFailed(let error):
                state.isStreaming = false
                state.errorMessage = error.localizedDescription
                return updateStreamConnectionState(
                    state: &state,
                    newValue: .failed(error.localizedDescription)
                )

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

    private func handleStreamEnvelopes(
        state: inout State,
        envelopes: [EventEnvelope]
    ) -> Effect<Action> {
        guard !envelopes.isEmpty else { return .none }

        var acceptedEvents: [EventEnvelope] = []
        var effects: [Effect<Action>] = []

        for envelope in envelopes {
            guard state.currentJobId == nil || envelope.jobId == state.currentJobId else {
                continue
            }
            if envelope.seq <= state.cursor {
                continue
            }
            state.cursor = max(state.cursor, envelope.seq)
            acceptedEvents.append(envelope)
            effects.append(handleLiveEvent(state: &state, envelope: envelope))
        }

        guard !acceptedEvents.isEmpty else {
            return .none
        }

        let streamStateEffect = updateStreamConnectionState(
            state: &state,
            newValue: .connected
        )
        effects.insert(streamStateEffect, at: 0)

        if let threadId = state.activeThread?.threadId {
            let eventsToPersist = acceptedEvents
            effects.append(
                .run { _ in
                    @Dependency(\.threadHistoryStore) var threadHistoryStore
                    for envelope in eventsToPersist {
                        do {
                            try await threadHistoryStore.appendLiveEvent(threadId, envelope)
                        } catch {
                            // 本地缓存失败不应影响主链路（消息流展示优先）。
                        }
                    }
                }
            )
        }

        return .merge(effects)
    }

    private static func sendEventsInBatches(
        _ events: [EventEnvelope],
        send: Send<Action>
    ) async {
        guard !events.isEmpty else { return }
        var index = 0
        while index < events.count {
            let end = min(index + streamBatchSize, events.count)
            await send(.streamEventsReceived(Array(events[index ..< end])))
            index = end
        }
    }

    private static func forwardStreamEvents(
        _ stream: AsyncStream<EventEnvelope>,
        send: Send<Action>
    ) async {
        let clock = ContinuousClock()
        var buffered: [EventEnvelope] = []
        var lastFlushAt = clock.now

        for await envelope in stream {
            buffered.append(envelope)
            let reachedBatchSize = buffered.count >= streamBatchSize
            let reachedDelay = lastFlushAt.duration(to: clock.now) >= streamBatchMaxDelay
            if reachedBatchSize || reachedDelay {
                let payload = buffered
                buffered.removeAll(keepingCapacity: true)
                await send(.streamEventsReceived(payload))
                lastFlushAt = clock.now
            }
        }

        if !buffered.isEmpty {
            await send(.streamEventsReceived(buffered))
        }
    }

    /// 处理实时流事件（会触发 delegate / stopStreaming 副作用）
    private func handleLiveEvent(state: inout State, envelope: EventEnvelope) -> Effect<Action> {
        var messages = state.messages
        var pendingAssistantDeltas = state.pendingAssistantDeltas
        var jobState = state.jobState
        var isApprovalLocked = state.isApprovalLocked
        var errorMessage = state.errorMessage

        let output = applyEventEnvelope(
            messages: &messages,
            pendingAssistantDeltas: &pendingAssistantDeltas,
            jobState: &jobState,
            isApprovalLocked: &isApprovalLocked,
            errorMessage: &errorMessage,
            envelope: envelope,
            mode: .live
        )

        state.messages = messages
        state.pendingAssistantDeltas = pendingAssistantDeltas
        state.jobState = jobState
        state.isApprovalLocked = isApprovalLocked
        state.errorMessage = errorMessage

        if let approval = output.approvalRequired {
            state.pendingApprovalsById[approval.approvalId] = approval
            state.approvalOrder.removeAll { $0 == approval.approvalId }
            state.approvalOrder.append(approval.approvalId)
        }
        if let resolved = output.approvalResolved {
            if resolved.approvalId.isEmpty {
                state.pendingApprovalsById.removeAll()
                state.approvalOrder.removeAll()
            } else {
                state.pendingApprovalsById.removeValue(forKey: resolved.approvalId)
                state.approvalOrder.removeAll { $0 == resolved.approvalId }
            }
        }

        let latestPendingApproval = latestPendingApproval(
            pendingApprovalsById: state.pendingApprovalsById,
            approvalOrder: state.approvalOrder,
            preferredJobId: state.currentJobId
        )
        if latestPendingApproval != nil {
            state.isApprovalLocked = true
        } else if state.jobState != .waitingApproval {
            state.isApprovalLocked = false
        }

        var effect: Effect<Action> = .none
        if let latestPendingApproval {
            effect = .merge(effect, .send(.delegate(.approvalRequired(latestPendingApproval))))
        }
        if latestPendingApproval == nil, let resolved = output.approvalResolved {
            effect = .merge(
                effect,
                .send(.delegate(.approvalResolved(approvalId: resolved.approvalId, decision: resolved.decision)))
            )
        }
        if let finishedState = output.finishedJobState {
            effect = .merge(
                effect,
                .send(.delegate(.jobFinished(state: finishedState, jobId: envelope.jobId)))
            )
        }
        if output.shouldStopStreaming {
            effect = .merge(effect, .send(.stopStreaming))
        }
        return effect
    }

    private func updateStreamConnectionState(
        state: inout State,
        newValue: StreamConnectionState
    ) -> Effect<Action> {
        guard state.streamConnectionState != newValue else { return .none }
        state.streamConnectionState = newValue
        return .send(.delegate(.streamConnectionChanged(newValue)))
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
        var replayMessages = replay.messages
        var replayPendingDeltas = replay.pendingAssistantDeltas

        if replay.jobState?.isActive != true {
            finalizePendingAssistantMessages(
                messages: &replayMessages,
                pendingAssistantDeltas: &replayPendingDeltas
            )
        }

        state.messages = replayMessages
        state.pendingAssistantDeltas = replayPendingDeltas
        state.currentJobId = replay.currentJobId
        state.cursor = replay.cursor
        state.jobState = replay.jobState
        state.isApprovalLocked = replay.isApprovalLocked
        state.pendingApprovalsById = replay.pendingApprovalsById
        state.approvalOrder = replay.approvalOrder
        state.errorMessage = replay.errorMessage

        var effect: Effect<Action> = .none
        if let approval = replay.pendingApproval {
            effect = .merge(effect, .send(.delegate(.approvalRequired(approval))))
        }

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
            return effect
        }
        return .merge(
            effect,
            .send(.startStreaming(jobId: activeJobId, cursor: replay.cursor))
        )
    }

    /// 基于线程游标执行远端增量同步
    private static func syncThreadHistory(
        threadId: String,
        apiClient: APIClient,
        threadHistoryStore: ThreadHistoryStore
    ) async throws -> ThreadHistorySyncOutcome {
        var cursor = try await threadHistoryStore.loadCursor(threadId)
        let originalCursor = cursor
        var hasResetOnce = false
        var didMutateCache = false

        while true {
            do {
                let page = try await apiClient.listThreadEvents(threadId, cursor, Self.threadHistoryPageLimit)
                if page.hasMore, page.nextCursor <= cursor {
                    throw CodexError.invalidState
                }
                try await threadHistoryStore.mergeRemotePage(threadId, cursor, page)
                if !page.data.isEmpty || page.nextCursor > cursor {
                    didMutateCache = true
                }
                cursor = page.nextCursor
                if !page.hasMore {
                    break
                }
            } catch let error as CodexError where error == .cursorExpired {
                if hasResetOnce {
                    throw error
                }
                hasResetOnce = true
                try await threadHistoryStore.resetThread(threadId)
                cursor = -1
                didMutateCache = true
            }
        }

        if hasResetOnce || didMutateCache || cursor != originalCursor {
            let syncedEvents = try await threadHistoryStore.loadCachedEvents(threadId)
            return ThreadHistorySyncOutcome(events: syncedEvents, shouldApply: true)
        }
        return ThreadHistorySyncOutcome(events: [], shouldApply: false)
    }

    private static func refreshThreadHistoryFromRemote(threadId: String) -> Effect<Action> {
        .run { send in
            @Dependency(\.apiClient) var apiClient
            @Dependency(\.threadHistoryStore) var threadHistoryStore

            do {
                let syncResult = try await Self.syncThreadHistory(
                    threadId: threadId,
                    apiClient: apiClient,
                    threadHistoryStore: threadHistoryStore
                )
                if syncResult.shouldApply {
                    await send(.threadHistorySyncResponse(threadId: threadId, .success(syncResult.events)))
                } else {
                    await send(.threadHistorySyncNoChange(threadId: threadId))
                }
            } catch {
                await send(
                    .threadHistorySyncResponse(
                        threadId: threadId,
                        .failure(CodexError.from(error))
                    )
                )
            }
        }
    }

    private func shouldResumeStreamingAfterSync(state: State) -> Bool {
        guard let activeState = state.jobState, activeState.isActive else { return false }
        switch state.streamConnectionState {
        case .idle, .failed:
            return true
        case .connecting, .connected:
            return false
        }
    }

    /// 将线程历史事件回放为聊天状态
    private func replayThreadEvents(_ events: [EventEnvelope]) -> ThreadHistoryReplay {
        var replay = ThreadHistoryReplay()
        var lastSeqByJob: [String: Int] = [:]
        var pendingApprovalsById: [String: Approval] = [:]
        var approvalOrder: [String] = []

        for envelope in events {
            replay.currentJobId = envelope.jobId
            lastSeqByJob[envelope.jobId] = max(lastSeqByJob[envelope.jobId] ?? -1, envelope.seq)

            let output = applyEventEnvelope(
                messages: &replay.messages,
                pendingAssistantDeltas: &replay.pendingAssistantDeltas,
                jobState: &replay.jobState,
                isApprovalLocked: &replay.isApprovalLocked,
                errorMessage: &replay.errorMessage,
                envelope: envelope,
                mode: .replay
            )

            if let approval = output.approvalRequired {
                pendingApprovalsById[approval.approvalId] = approval
                approvalOrder.removeAll { $0 == approval.approvalId }
                approvalOrder.append(approval.approvalId)
            }
            if let resolved = output.approvalResolved {
                if resolved.approvalId.isEmpty {
                    pendingApprovalsById.removeAll()
                    approvalOrder.removeAll()
                } else {
                    pendingApprovalsById.removeValue(forKey: resolved.approvalId)
                    approvalOrder.removeAll { $0 == resolved.approvalId }
                }
            }
        }

        if replay.jobState?.isActive != true {
            replay.isApprovalLocked = false
        }
        replay.cursor = replay.currentJobId.flatMap { lastSeqByJob[$0] } ?? -1
        replay.pendingApprovalsById = pendingApprovalsById
        replay.approvalOrder = approvalOrder
        replay.pendingApproval = latestPendingApproval(
            pendingApprovalsById: pendingApprovalsById,
            approvalOrder: approvalOrder,
            preferredJobId: replay.currentJobId
        )
        return replay
    }

    private func latestPendingApproval(
        pendingApprovalsById: [String: Approval],
        approvalOrder: [String],
        preferredJobId: String?
    ) -> Approval? {
        if let preferredJobId {
            for approvalId in approvalOrder.reversed() {
                guard let approval = pendingApprovalsById[approvalId] else { continue }
                if approval.jobId == preferredJobId {
                    return approval
                }
            }
        }
        for approvalId in approvalOrder.reversed() {
            if let approval = pendingApprovalsById[approvalId] {
                return approval
            }
        }
        return nil
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
        messages: inout [Message],
        pendingAssistantDeltas: inout [String: MessageDelta],
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

        if var delta = pendingAssistantDeltas[itemId] {
            delta.markComplete()
            pendingAssistantDeltas[itemId] = nil
            upsertMessage(&messages, with: delta.toMessage())
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
            upsertMessage(&messages, with: message)
        }
    }

    private func applyAssistantDelta(
        messages: inout [Message],
        pendingAssistantDeltas: inout [String: MessageDelta],
        envelope: EventEnvelope
    ) {
        _ = messages
        guard let payload = envelope.payload else { return }
        let itemId = payload["itemId"]?.stringValue ?? "assistant-\(envelope.jobId)-\(envelope.seq)"
        let delta = payload["delta"]?.stringValue
            ?? payload["textDelta"]?.stringValue
            ?? payload["text"]?.stringValue
            ?? ""
        guard !delta.isEmpty else { return }

        if var existing = pendingAssistantDeltas[itemId] {
            existing.append(delta)
            pendingAssistantDeltas[itemId] = existing
        } else {
            var newDelta = MessageDelta(id: itemId, text: "", sender: .assistant)
            newDelta.append(delta)
            pendingAssistantDeltas[itemId] = newDelta
        }
    }

    /// 收敛所有未完成的助手增量（用于收到 job.finished 但缺少 item.completed 的场景）
    private func finalizePendingAssistantMessages(
        messages: inout [Message],
        pendingAssistantDeltas: inout [String: MessageDelta]
    ) {
        guard !pendingAssistantDeltas.isEmpty else { return }
        let orderedKeys = pendingAssistantDeltas.keys.sorted()
        for key in orderedKeys {
            guard var delta = pendingAssistantDeltas[key] else { continue }
            delta.markComplete()
            upsertMessage(&messages, with: delta.toMessage())
        }
        pendingAssistantDeltas.removeAll()
    }

    private func approvalResolvedPayload(from envelope: EventEnvelope) -> ApprovalResolvedPayload {
        ApprovalResolvedPayload(
            approvalId:
                envelope.payload?["approvalId"]?.stringValue
                ?? envelope.payload?["approval_id"]?.stringValue
                ?? "",
            decision: envelope.payload?["decision"]?.stringValue
        )
    }

    private func applyEventEnvelope(
        messages: inout [Message],
        pendingAssistantDeltas: inout [String: MessageDelta],
        jobState: inout JobState?,
        isApprovalLocked: inout Bool,
        errorMessage: inout String?,
        envelope: EventEnvelope,
        mode: EventApplyMode
    ) -> EventApplyOutput {
        var output = EventApplyOutput()

        switch envelope.eventType {
        case .jobState:
            if let raw = envelope.payload?["state"]?.stringValue, let mapped = JobState(rawValue: raw) {
                jobState = mapped
                if mapped != .waitingApproval {
                    isApprovalLocked = false
                }
            }

        case .approvalRequired:
            isApprovalLocked = true
            jobState = .waitingApproval
            if let payload = envelope.payload,
               let approval = Approval.fromPayload(payload, fallbackJobId: envelope.jobId)
            {
                output.approvalRequired = approval
            }

        case .approvalResolved:
            isApprovalLocked = false
            output.approvalResolved = approvalResolvedPayload(from: envelope)

        case .itemAgentMessageDelta:
            applyAssistantDelta(
                messages: &messages,
                pendingAssistantDeltas: &pendingAssistantDeltas,
                envelope: envelope
            )

        case .itemStarted, .itemCompleted:
            if mode == .replay,
               let userMessage = userMessage(from: envelope)
            {
                upsertMessage(&messages, with: userMessage)
            }
            handleAssistantCompletionIfNeeded(
                messages: &messages,
                pendingAssistantDeltas: &pendingAssistantDeltas,
                envelope: envelope
            )

        case .jobFinished:
            if let raw = envelope.payload?["state"]?.stringValue, let mapped = JobState(rawValue: raw) {
                jobState = mapped
            }
            finalizePendingAssistantMessages(
                messages: &messages,
                pendingAssistantDeltas: &pendingAssistantDeltas
            )
            if mode == .live {
                output.finishedJobState = jobState ?? .done
                output.shouldStopStreaming = true
            }

        case .error:
            errorMessage = envelope.payload?["message"]?.stringValue ?? "SSE 出现错误"

        default:
            break
        }

        return output
    }

    private struct ApprovalResolvedPayload: Sendable {
        let approvalId: String
        let decision: String?
    }

    private struct EventApplyOutput: Sendable {
        var approvalRequired: Approval?
        var approvalResolved: ApprovalResolvedPayload?
        var finishedJobState: JobState?
        var shouldStopStreaming = false
    }

    private enum EventApplyMode: Equatable, Sendable {
        case live
        case replay
    }
}

private func markMessageStatus(
    state: inout ChatFeature.State,
    messageId: String,
    status: Message.Status
) {
    guard let idx = state.messages.firstIndex(where: { $0.id == messageId }) else { return }
    state.messages[idx].status = status
}

private func messageText(in messages: [Message], messageId: String) -> String {
    messages.first(where: { $0.id == messageId })?.text ?? ""
}

private struct ThreadHistoryReplay: Sendable {
    var currentJobId: String?
    var cursor: Int = -1
    var messages: [Message] = []
    var pendingAssistantDeltas: [String: MessageDelta] = [:]
    var pendingApprovalsById: [String: Approval] = [:]
    var approvalOrder: [String] = []
    var jobState: JobState?
    var isApprovalLocked = false
    var errorMessage: String?
    var pendingApproval: Approval?
}
