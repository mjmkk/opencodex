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
        case startStreaming(sessionId: String, fromSeq: Int?)
        case streamEventReceived(TerminalStreamFrame)
        case streamFailed(CodexError)
        case sendInput
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
                state.activeThread = thread
                state.errorMessage = nil
                guard state.isPresented else {
                    return .none
                }
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
                    return resetAndOpenForCurrentThread(state: &state)
                } else {
                    state.isPresented = false
                    state.connectionState = .idle
                    state.errorMessage = nil
                    state.inputText = ""
                    return .merge(
                        .cancel(id: CancelID.stream),
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
                return .run { send in
                    @Dependency(\.apiClient) var apiClient
                    await send(
                        .openSessionResponse(
                            Result {
                                try await apiClient.openThreadTerminal(
                                    threadId,
                                    ThreadTerminalOpenRequest(cols: 120, rows: 24)
                                )
                            }.mapError { CodexError.from($0) }
                        )
                    )
                }

            case .openSessionResponse(.success(let response)):
                state.isOpening = false
                state.session = response.session
                state.connectionState = .connecting
                if !response.reused {
                    state.terminalText = ""
                    state.latestSeq = -1
                }
                return .send(.startStreaming(sessionId: response.session.sessionId, fromSeq: -1))

            case .openSessionResponse(.failure(let error)):
                state.isOpening = false
                state.connectionState = .failed(error.localizedDescription)
                state.errorMessage = error.localizedDescription
                return .none

            case .startStreaming(let sessionId, let fromSeq):
                state.connectionState = .connecting
                return .run { send in
                    @Dependency(\.terminalSocketClient) var terminalSocketClient
                    do {
                        let stream = try await terminalSocketClient.subscribe(sessionId, fromSeq)
                        for try await frame in stream {
                            await send(.streamEventReceived(frame))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.streamFailed(CodexError.from(error)))
                    }
                }
                .cancellable(id: CancelID.stream, cancelInFlight: true)

            case .streamEventReceived(let frame):
                if let seq = frame.seq {
                    state.latestSeq = max(state.latestSeq, seq)
                }

                switch frame.type {
                case "ready":
                    state.connectionState = .connected
                    if let cwd = frame.cwd {
                        state.session?.cwd = cwd
                    }
                    if let threadId = frame.threadId {
                        state.session?.threadId = threadId
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

                case "pong":
                    break

                default:
                    break
                }
                return .none

            case .streamFailed(let error):
                state.connectionState = .failed(error.localizedDescription)
                state.errorMessage = error.localizedDescription
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
                let payload = raw.hasSuffix("\n") ? raw : raw + "\n"
                return .run { send in
                    @Dependency(\.terminalSocketClient) var terminalSocketClient
                    do {
                        try await terminalSocketClient.sendInput(payload)
                    } catch {
                        await send(.sendInputFailed(CodexError.from(error)))
                    }
                }

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
                state.isClosing = false
                state.session = response.session
                state.isPresented = false
                state.connectionState = .idle
                return .merge(
                    .cancel(id: CancelID.stream),
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
        state.terminalText = ""
        state.latestSeq = -1
        state.connectionState = .connecting
        state.errorMessage = nil
        return .merge(
            .cancel(id: CancelID.stream),
            .run { _ in
                @Dependency(\.terminalSocketClient) var terminalSocketClient
                await terminalSocketClient.disconnect()
            },
            .send(.openSession)
        )
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
}
