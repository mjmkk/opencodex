import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct TerminalFeatureTests {
    private func makeThread(id: String, cwd: String = "/repo/\(UUID().uuidString)") -> CodexWorker.Thread {
        CodexWorker.Thread(
            threadId: id,
            preview: nil,
            cwd: cwd,
            createdAt: "2026-02-24T00:00:00.000Z",
            updatedAt: "2026-02-24T00:00:00.000Z",
            modelProvider: "openai"
        )
    }

    @Test
    func reusedSessionUsesIncrementalFromSeq() async {
        let thread = makeThread(id: "thr_terminal_reused")
        var initialState = TerminalFeature.State()
        initialState.activeThread = thread
        initialState.isPresented = true
        initialState.terminalText = "cached-output"
        initialState.latestSeq = 8
        initialState.threadBuffers[thread.threadId] = .init(text: "cached-output", latestSeq: 8)

        let store = TestStore(initialState: initialState) {
            TerminalFeature()
        } withDependencies: { dependencies in
            dependencies.terminalSocketClient = TerminalSocketClient(
                subscribe: { _, _ in throw CancellationError() },
                sendInput: { _ in },
                sendResize: { _, _ in },
                disconnect: {}
            )
        }
        store.exhaustivity = .off

        let response = ThreadTerminalOpenResponse(
            session: TerminalSessionSnapshot(
                sessionId: "term_reused",
                threadId: thread.threadId,
                cwd: thread.cwd ?? "/repo",
                shell: "/bin/zsh",
                pid: 100,
                status: "running",
                createdAt: nil,
                lastActiveAt: nil,
                cols: 120,
                rows: 24,
                exitCode: nil,
                signal: nil,
                nextSeq: 9,
                clientCount: 1
            ),
            reused: true,
            wsPath: nil
        )

        await store.send(.openSessionResponse(.success(response))) {
            $0.isOpening = false
            $0.session = response.session
            $0.connectionState = .connecting
            $0.reconnectAttempt = 0
            $0.lastSentCols = 120
            $0.lastSentRows = 24
            $0.terminalText = "cached-output"
            $0.latestSeq = 8
        }

        await store.receive({ action in
            if case .startStreaming(let sessionId, let fromSeq) = action {
                return sessionId == "term_reused" && fromSeq == 8
            }
            return false
        }) {
            $0.connectionState = .connecting
        }
    }

    @Test
    func freshSessionResetsBufferAndStartsFromNegativeOne() async {
        let thread = makeThread(id: "thr_terminal_fresh")
        var initialState = TerminalFeature.State()
        initialState.activeThread = thread
        initialState.isPresented = true
        initialState.terminalText = "stale-output"
        initialState.latestSeq = 20
        initialState.threadBuffers[thread.threadId] = .init(text: "stale-output", latestSeq: 20)

        let store = TestStore(initialState: initialState) {
            TerminalFeature()
        } withDependencies: { dependencies in
            dependencies.terminalSocketClient = TerminalSocketClient(
                subscribe: { _, _ in throw CancellationError() },
                sendInput: { _ in },
                sendResize: { _, _ in },
                disconnect: {}
            )
        }
        store.exhaustivity = .off

        let response = ThreadTerminalOpenResponse(
            session: TerminalSessionSnapshot(
                sessionId: "term_fresh",
                threadId: thread.threadId,
                cwd: thread.cwd ?? "/repo",
                shell: "/bin/zsh",
                pid: 101,
                status: "running",
                createdAt: nil,
                lastActiveAt: nil,
                cols: 120,
                rows: 24,
                exitCode: nil,
                signal: nil,
                nextSeq: 0,
                clientCount: 1
            ),
            reused: false,
            wsPath: nil
        )

        await store.send(.openSessionResponse(.success(response))) {
            $0.isOpening = false
            $0.session = response.session
            $0.connectionState = .connecting
            $0.reconnectAttempt = 0
            $0.lastSentCols = 120
            $0.lastSentRows = 24
            $0.terminalText = ""
            $0.latestSeq = -1
            $0.threadBuffers[thread.threadId] = .init(text: "", latestSeq: -1)
        }

        await store.receive({ action in
            if case .startStreaming(let sessionId, let fromSeq) = action {
                return sessionId == "term_fresh" && fromSeq == -1
            }
            return false
        }) {
            $0.connectionState = .connecting
        }
    }

    @Test
    func viewportChangeTriggersResizeWhenConnected() async {
        let thread = makeThread(id: "thr_terminal_resize")
        var initialState = TerminalFeature.State()
        initialState.activeThread = thread
        initialState.isPresented = true
        initialState.connectionState = .connected
        initialState.session = TerminalSessionSnapshot(
            sessionId: "term_resize",
            threadId: thread.threadId,
            cwd: thread.cwd ?? "/repo",
            shell: "/bin/zsh",
            pid: 102,
            status: "running",
            createdAt: nil,
            lastActiveAt: nil,
            cols: 120,
            rows: 24,
            exitCode: nil,
            signal: nil,
            nextSeq: 1,
            clientCount: 1
        )
        initialState.viewportCols = 120
        initialState.viewportRows = 24
        initialState.lastSentCols = 120
        initialState.lastSentRows = 24

        actor ResizeRecorder {
            private var values: [(Int, Int)] = []

            func append(_ value: (Int, Int)) {
                values.append(value)
            }

            func snapshot() -> [(Int, Int)] {
                values
            }
        }
        let resizeRecorder = ResizeRecorder()
        let store = TestStore(initialState: initialState) {
            TerminalFeature()
        } withDependencies: { dependencies in
            dependencies.terminalSocketClient = TerminalSocketClient(
                subscribe: { _, _ in throw CancellationError() },
                sendInput: { _ in },
                sendResize: { cols, rows in
                    await resizeRecorder.append((cols, rows))
                },
                disconnect: {}
            )
        }
        store.exhaustivity = .off

        await store.send(.viewportChanged(width: 1000, height: 500)) {
            $0.viewportCols = 121
            $0.viewportRows = 24
        }

        await store.receive({ action in
            if case .sendResize = action {
                return true
            }
            return false
        }) {
            $0.lastSentCols = 121
            $0.lastSentRows = 24
        }

        let resizeCalls = await resizeRecorder.snapshot()
        #expect(resizeCalls.count == 1)
        #expect(resizeCalls[0].0 == 121)
        #expect(resizeCalls[0].1 == 24)
    }

    @Test
    func streamFailureSchedulesReconnectAndReusesCursor() async {
        let clock = TestClock()
        let thread = makeThread(id: "thr_terminal_reconnect")

        var initialState = TerminalFeature.State()
        initialState.activeThread = thread
        initialState.isPresented = true
        initialState.connectionState = .connected
        initialState.latestSeq = 6
        initialState.session = TerminalSessionSnapshot(
            sessionId: "term_reconnect",
            threadId: thread.threadId,
            cwd: thread.cwd ?? "/repo",
            shell: "/bin/zsh",
            pid: 103,
            status: "running",
            createdAt: nil,
            lastActiveAt: nil,
            cols: 120,
            rows: 24,
            exitCode: nil,
            signal: nil,
            nextSeq: 7,
            clientCount: 1
        )

        let store = TestStore(initialState: initialState) {
            TerminalFeature()
        } withDependencies: { dependencies in
            dependencies.continuousClock = clock
            dependencies.terminalSocketClient = TerminalSocketClient(
                subscribe: { _, _ in throw CancellationError() },
                sendInput: { _ in },
                sendResize: { _, _ in },
                disconnect: {}
            )
        }
        store.exhaustivity = .off

        await store.send(.streamFailed(.connectionFailed("network lost"))) {
            $0.connectionState = .failed("连接失败: network lost")
            $0.errorMessage = "连接失败: network lost"
        }

        await store.receive({ action in
            if case .reconnectNow = action {
                return true
            }
            return false
        }) {
            $0.reconnectAttempt = 1
            $0.connectionState = .connecting
        }

        await clock.advance(by: .seconds(1))

        await store.receive({ action in
            if case .startStreaming(let sessionId, let fromSeq) = action {
                return sessionId == "term_reconnect" && fromSeq == 6
            }
            return false
        }) {
            $0.connectionState = .connecting
        }
    }
}
