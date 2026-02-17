import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ChatFeatureEventTests {
    @Test
    func liveItemCompletedWithoutDeltaFallsBackToCompletedText() async {
        var initialState = ChatFeature.State()
        initialState.currentJobId = "job_live_1"
        let store = TestStore(initialState: initialState) {
            ChatFeature()
        }
        store.exhaustivity = .off

        let envelope = EventEnvelope(
            type: EventType.itemCompleted.rawValue,
            ts: "2026-02-17T00:00:00.000Z",
            jobId: "job_live_1",
            seq: 7,
            payload: [
                "item": .object([
                    "id": .string("assistant_item_live"),
                    "type": .string("agentMessage"),
                    "text": .string("来自 completed 的完整文本"),
                ]),
            ]
        )

        await store.send(.streamEventReceived(envelope))
        await store.skipReceivedActions()

        #expect(store.state.cursor == 7)
        #expect(store.state.messages.count == 1)
        #expect(store.state.messages.first?.id == "assistant_item_live")
        #expect(store.state.messages.first?.text == "来自 completed 的完整文本")
        #expect(store.state.pendingAssistantDeltas.isEmpty)
    }

    @Test
    func replayItemCompletedWithoutDeltaUsesSameFallback() async {
        var initialState = ChatFeature.State()
        initialState.activeThread = Thread(
            threadId: "thread_replay_1",
            preview: nil,
            cwd: nil,
            createdAt: nil,
            updatedAt: nil,
            modelProvider: nil
        )
        let store = TestStore(initialState: initialState) {
            ChatFeature()
        }
        store.exhaustivity = .off

        let envelope = EventEnvelope(
            type: EventType.itemCompleted.rawValue,
            ts: "2026-02-17T00:01:00.000Z",
            jobId: "job_replay_1",
            seq: 3,
            payload: [
                "item": .object([
                    "id": .string("assistant_item_replay"),
                    "type": .string("agentMessage"),
                    "text": .string("回放文本"),
                ]),
            ]
        )

        await store.send(
            .threadHistorySyncResponse(
                threadId: "thread_replay_1",
                .success([envelope])
            )
        )

        #expect(store.state.currentJobId == "job_replay_1")
        #expect(store.state.cursor == 3)
        #expect(store.state.messages.count == 1)
        #expect(store.state.messages.first?.id == "assistant_item_replay")
        #expect(store.state.messages.first?.text == "回放文本")
        #expect(store.state.pendingAssistantDeltas.isEmpty)
    }
}
