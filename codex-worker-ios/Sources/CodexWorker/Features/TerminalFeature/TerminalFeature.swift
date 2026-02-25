//
//  TerminalFeature.swift
//  CodexWorker
//
//  半屏远端终端 Feature
//

import ComposableArchitecture
import Foundation

@Reducer
public struct TerminalFeature {
    private enum CancelID {
        case stream
        case reconnect
        case resizeDebounce
    }

    /// 内存中最多缓存的线程终端缓冲数量（超出时淘汰非当前线程的最旧缓冲）
    private static let maxCachedThreadBuffers = 10

    public struct ThreadBuffer: Equatable, Sendable {
        public var text: String
        public var latestSeq: Int

        public init(text: String = "", latestSeq: Int = -1) {
            self.text = text
            self.latestSeq = latestSeq
        }
    }

    @ObservableState
    public struct State: Equatable {
        public enum ConnectionState: Equatable, Sendable {
            case idle
            case connecting
            case connected
            case failed(String)
        }

        public var activeThread: Thread?
        public var isPresented = false
        public var heightRatio: Double = 0.5
        public var session: TerminalSessionSnapshot?
        public var connectionState: ConnectionState = .idle
        public var terminalText = ""
        public var inputText = ""
        public var latestSeq = -1
        public var isOpening = false
        public var isClosing = false
        public var errorMessage: String?
        public var showRiskNotice = false
        public var pendingInputQueue: [String] = []

        // 线程内存缓冲（仅前端内存态，不落盘）
        public var threadBuffers: [String: ThreadBuffer] = [:]

        // 终端逻辑尺寸（用于 PTY resize）
        public var viewportCols = 120
        public var viewportRows = 24
        public var lastSentCols = 120
        public var lastSentRows = 24

        // 自动重连状态
        public var reconnectAttempt = 0

        public var canSendInput: Bool {
            isPresented && session?.status == "running"
        }

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setActiveThread(Thread?)
        case togglePresented
        case setPresented(Bool)
        case openSession
        case openSessionResponse(Result<ThreadTerminalOpenResponse, CodexError>)
        case loadRiskNotice
        case riskNoticeLoaded(Bool)
        case dismissRiskNotice
        case startStreaming(sessionId: String, fromSeq: Int?)
        case streamEventReceived(TerminalStreamFrame)
        case streamCompleted
        case streamFailed(CodexError)
        case reconnectNow
        case viewportChanged(width: Double, height: Double)
        case resizeDebounced
        case sendResize
        case sendResizeFailed(CodexError)
        case sendInput
        case sendRawInput(String)
        case enqueueInput(String)
        case clearOutput
        case sendInputFailed(CodexError)
        case closeSession
        case closeSessionResponse(Result<TerminalCloseResponse, CodexError>)
        case clearError
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .setActiveThread(let thread):
                let previousThreadId = state.activeThread?.threadId
                let nextThreadId = thread?.threadId
                if previousThreadId != nextThreadId {
                    persistBuffer(state: &state, threadId: previousThreadId)
                    state.pendingInputQueue.removeAll()
                }

                state.activeThread = thread
                state.errorMessage = nil

                guard state.isPresented else {
                    restoreBufferIfNeeded(state: &state)
                    return .none
                }

                restoreBufferIfNeeded(state: &state)
                return resetAndOpenForCurrentThread(state: &state)

            case .togglePresented:
                return .send(.setPresented(!state.isPresented))

            case .setPresented(let presented):
                if presented {
                    guard state.activeThread != nil else {
                        state.errorMessage = "请先选择线程，再打开终端"
                        return .none
                    }
                    state.isPresented = true
                    restoreBufferIfNeeded(state: &state)
                    return .merge(
                        resetAndOpenForCurrentThread(state: &state),
                        .send(.loadRiskNotice)
                    )
                } else {
                    persistBuffer(state: &state, threadId: state.activeThread?.threadId)
                    state.isPresented = false
                    state.connectionState = .idle
                    state.errorMessage = nil
                    state.showRiskNotice = false
                    state.pendingInputQueue.removeAll()
                    state.inputText = ""
                    state.session = nil
                    state.isOpening = false
                    state.isClosing = false
                    state.reconnectAttempt = 0
                    return .merge(
                        .cancel(id: CancelID.stream),
                        .cancel(id: CancelID.reconnect),
                        .cancel(id: CancelID.resizeDebounce),
                        .run { _ in
                            @Dependency(\.terminalSocketClient) var terminalSocketClient
                            await terminalSocketClient.disconnect()
                        }
                    )
                }

            case .openSession:
                guard let threadId = state.activeThread?.threadId else {
                    return .none
                }
                state.isOpening = true
                state.connectionState = .connecting
                state.errorMessage = nil
                let cols = state.viewportCols
                let rows = state.viewportRows
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .openSessionResponse(
                            Result {
                                try await apiClient.openThreadTerminal(
                                    threadId,
                                    ThreadTerminalOpenRequest(cols: cols, rows: rows)
                                )
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .openSessionResponse(.success(let response)):
                state.isOpening = false
                state.session = response.session
                state.connectionState = .connecting
                state.reconnectAttempt = 0
                state.lastSentCols = response.session.cols
                state.lastSentRows = response.session.rows

                let activeThreadId = state.activeThread?.threadId ?? response.session.threadId
                if !response.reused {
                    state.terminalText = ""
                    state.latestSeq = -1
                    state.threadBuffers[activeThreadId] = ThreadBuffer(text: "", latestSeq: -1)
                } else {
                    restoreBufferIfNeeded(state: &state)
                }

                let fromSeq = max(-1, state.latestSeq)
                return .send(.startStreaming(sessionId: response.session.sessionId, fromSeq: fromSeq))

            case .openSessionResponse(.failure(let error)):
                state.isOpening = false
                state.connectionState = .failed(error.localizedDescription)
                state.errorMessage = error.localizedDescription
                return .none

            case .loadRiskNotice:
                return .run { send in
                    @Dependency(\.terminalRiskNoticeStore) var terminalRiskNoticeStore
                    let shouldShow = terminalRiskNoticeStore.shouldShowOnNextOpen()
                    await send(.riskNoticeLoaded(shouldShow))
                }

            case .riskNoticeLoaded(let shouldShow):
                state.showRiskNotice = shouldShow
                guard shouldShow else { return .none }
                return .run { _ in
                    @Dependency(\.terminalRiskNoticeStore) var terminalRiskNoticeStore
                    terminalRiskNoticeStore.markShown()
                }

            case .dismissRiskNotice:
                state.showRiskNotice = false
                return .none

            case .startStreaming(let sessionId, let fromSeq):
                state.connectionState = .connecting
                return .merge(
                    .cancel(id: CancelID.reconnect),
                    .run { send in
                        @Dependency(\.terminalSocketClient) var terminalSocketClient
                        do {
                            let stream = try await terminalSocketClient.subscribe(sessionId, fromSeq)
                            for try await frame in stream {
                                await send(.streamEventReceived(frame))
                            }
                            await send(.streamCompleted)
                        } catch is CancellationError {
                            return
                        } catch {
                            await send(.streamFailed(CodexError.from(error)))
                        }
                    }
                    .cancellable(id: CancelID.stream, cancelInFlight: true)
                )

            case .streamEventReceived(let frame):
                if let seq = frame.seq {
                    state.latestSeq = max(state.latestSeq, seq)
                }

                switch frame.type {
                case "ready":
                    state.connectionState = .connected
                    state.reconnectAttempt = 0
                    if let cwd = frame.cwd {
                        state.session?.cwd = cwd
                    }
                    if let threadId = frame.threadId {
                        state.session?.threadId = threadId
                    }
                    if let transportMode = frame.transportMode, !transportMode.isEmpty {
                        state.session?.transportMode = transportMode
                    }
                    var effects: [Effect<Action>] = []
                    if state.lastSentCols != state.viewportCols || state.lastSentRows != state.viewportRows {
                        effects.append(.send(.sendResize))
                    }
                    if !state.pendingInputQueue.isEmpty {
                        let queuedInputs = state.pendingInputQueue
                        state.pendingInputQueue.removeAll()
                        effects.append(
                            .merge(queuedInputs.map { payload in
                                .send(.sendRawInput(payload))
                            })
                        )
                    }
                    if !effects.isEmpty {
                        return .merge(effects)
                    }

                case "output":
                    if let data = frame.data, !data.isEmpty {
                        state.terminalText += data
                        trimTerminalTextIfNeeded(state: &state)
                    }

                case "exit":
                    state.session?.status = "exited"
                    state.session?.exitCode = frame.exitCode
                    state.session?.signal = frame.signal

                case "error":
                    let message = frame.message ?? "终端流发生错误"
                    state.errorMessage = message
                    state.connectionState = .failed(message)
                    if frame.code == "TERMINAL_CURSOR_EXPIRED" {
                        state.latestSeq = -1
                    }

                case "pong", "ping":
                    break

                default:
                    break
                }

                persistBuffer(state: &state, threadId: state.activeThread?.threadId)
                return .none

            case .streamCompleted:
                return scheduleReconnectIfNeeded(state: &state, fallbackMessage: "终端连接已断开，正在重连…")

            case .streamFailed(let error):
                state.connectionState = .failed(error.localizedDescription)
                state.errorMessage = error.localizedDescription
                return scheduleReconnectIfNeeded(state: &state, fallbackMessage: "终端连接失败，正在重连…")

            case .reconnectNow:
                guard canReconnect(state: state), let sessionId = state.session?.sessionId else {
                    return .none
                }
                let delay = min(1 << min(state.reconnectAttempt, 3), 8)
                state.reconnectAttempt += 1
                let fromSeq = max(-1, state.latestSeq)
                state.connectionState = .connecting
                return .run { send in
                    @Dependency(\.continuousClock) var clock
                    try await clock.sleep(for: .seconds(delay))
                    await send(.startStreaming(sessionId: sessionId, fromSeq: fromSeq))
                }
                .cancellable(id: CancelID.reconnect, cancelInFlight: true)

            case .viewportChanged(let width, let height):
                let nextCols = max(40, Int(floor(width / 8.2)))
                // 扣除顶部标题与输入栏高度后估算可视行数
                let usableHeight = max(80.0, height - 86.0)
                let nextRows = max(8, Int(floor(usableHeight / 17.2)))

                guard nextCols != state.viewportCols || nextRows != state.viewportRows else {
                    return .none
                }
                state.viewportCols = nextCols
                state.viewportRows = nextRows
                guard state.connectionState == .connected else {
                    return .none
                }
                return .run { send in
                    @Dependency(\.continuousClock) var clock
                    try await clock.sleep(for: .milliseconds(160))
                    await send(.resizeDebounced)
                }
                .cancellable(id: CancelID.resizeDebounce, cancelInFlight: true)

            case .resizeDebounced:
                return .send(.sendResize)

            case .sendResize:
                guard let session = state.session, session.status == "running" else {
                    return .none
                }
                if session.transportMode == "pipe" {
                    return .none
                }
                let cols = state.viewportCols
                let rows = state.viewportRows
                guard cols != state.lastSentCols || rows != state.lastSentRows else {
                    return .none
                }
                state.lastSentCols = cols
                state.lastSentRows = rows
                return .run { send in
                    @Dependency(\.terminalSocketClient) var terminalSocketClient
                    do {
                        try await terminalSocketClient.sendResize(cols, rows)
                    } catch {
                        await send(.sendResizeFailed(CodexError.from(error)))
                    }
                }

            case .sendResizeFailed(let error):
                state.errorMessage = "终端尺寸同步失败：\(error.localizedDescription)"
                return .none

            case .sendInput:
                guard state.canSendInput else {
                    return .none
                }
                let raw = state.inputText
                guard !raw.isEmpty else {
                    return .none
                }
                state.inputText = ""
                if state.session?.transportMode == "pipe" {
                    appendPipeCommandEcho(state: &state, command: raw)
                    persistBuffer(state: &state, threadId: state.activeThread?.threadId)
                }
                let payload = raw.hasSuffix("\n") ? raw : raw + "\n"
                return sendSocketInput(payload)

            case .sendRawInput(let payload):
                guard state.canSendInput else {
                    return .none
                }
                guard !payload.isEmpty else {
                    return .none
                }
                return sendSocketInput(payload)

            case .enqueueInput(let payload):
                guard !payload.isEmpty else {
                    return .none
                }
                if state.canSendInput {
                    return .send(.sendRawInput(payload))
                }
                state.pendingInputQueue.append(payload)
                return .none

            case .clearOutput:
                state.terminalText = ""
                persistBuffer(state: &state, threadId: state.activeThread?.threadId)
                return .none

            case .sendInputFailed(let error):
                state.errorMessage = "发送失败：\(error.localizedDescription)"
                return .none

            case .closeSession:
                guard let sessionId = state.session?.sessionId else {
                    return .send(.setPresented(false))
                }
                state.isClosing = true
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .closeSessionResponse(
                            Result {
                                try await apiClient.closeTerminal(
                                    sessionId,
                                    TerminalCloseRequest(reason: "user_closed")
                                )
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .closeSessionResponse(.success(let response)):
                persistBuffer(state: &state, threadId: state.activeThread?.threadId)
                state.isClosing = false
                state.session = response.session
                state.isPresented = false
                state.connectionState = .idle
                state.reconnectAttempt = 0
                return .merge(
                    .cancel(id: CancelID.stream),
                    .cancel(id: CancelID.reconnect),
                    .cancel(id: CancelID.resizeDebounce),
                    .run { _ in
                        @Dependency(\.terminalSocketClient) var terminalSocketClient
                        await terminalSocketClient.disconnect()
                    }
                )

            case .closeSessionResponse(.failure(let error)):
                state.isClosing = false
                state.errorMessage = error.localizedDescription
                return .none

            case .clearError:
                state.errorMessage = nil
                return .none
            }
        }
    }

    private func resetAndOpenForCurrentThread(state: inout State) -> Effect<Action> {
        state.session = nil
        state.connectionState = .connecting
        state.errorMessage = nil
        state.isOpening = false
        state.isClosing = false
        state.reconnectAttempt = 0
        return .merge(
            .cancel(id: CancelID.stream),
            .cancel(id: CancelID.reconnect),
            .cancel(id: CancelID.resizeDebounce),
            .run { _ in
                @Dependency(\.terminalSocketClient) var terminalSocketClient
                await terminalSocketClient.disconnect()
            },
            .send(.openSession)
        )
    }

    private func restoreBufferIfNeeded(state: inout State) {
        guard let threadId = state.activeThread?.threadId else {
            state.terminalText = ""
            state.latestSeq = -1
            return
        }
        let buffer = state.threadBuffers[threadId] ?? ThreadBuffer()
        state.terminalText = buffer.text
        state.latestSeq = buffer.latestSeq
    }

    private func persistBuffer(state: inout State, threadId: String?) {
        guard let threadId else { return }
        state.threadBuffers[threadId] = ThreadBuffer(text: state.terminalText, latestSeq: state.latestSeq)

        // 超出上限时淘汰一个非当前线程的缓冲，防止内存无限增长
        if state.threadBuffers.count > Self.maxCachedThreadBuffers,
           let keyToEvict = state.threadBuffers.keys.first(where: { $0 != threadId })
        {
            state.threadBuffers.removeValue(forKey: keyToEvict)
        }
    }

    private func canReconnect(state: State) -> Bool {
        state.isPresented &&
            state.session?.status == "running" &&
            state.isClosing == false
    }

    private func scheduleReconnectIfNeeded(
        state: inout State,
        fallbackMessage: String
    ) -> Effect<Action> {
        guard canReconnect(state: state) else {
            return .none
        }
        if state.errorMessage == nil {
            state.errorMessage = fallbackMessage
        }
        return .send(.reconnectNow)
    }

    private func trimTerminalTextIfNeeded(state: inout State) {
        let maxChars = 200_000
        if state.terminalText.count <= maxChars {
            return
        }
        let startIndex = state.terminalText.index(
            state.terminalText.endIndex,
            offsetBy: -maxChars
        )
        state.terminalText = String(state.terminalText[startIndex...])
    }

    private func sendSocketInput(_ payload: String) -> Effect<Action> {
        .run { send in
            @Dependency(\.terminalSocketClient) var terminalSocketClient
            do {
                try await terminalSocketClient.sendInput(payload)
            } catch {
                await send(.sendInputFailed(CodexError.from(error)))
            }
        }
    }

    private func appendPipeCommandEcho(state: inout State, command: String) {
        let normalized = command.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return }

        if !state.terminalText.isEmpty, !state.terminalText.hasSuffix("\n") {
            state.terminalText += "\n"
        }
        state.terminalText += "$ \(normalized)\n"
        trimTerminalTextIfNeeded(state: &state)
    }
}
