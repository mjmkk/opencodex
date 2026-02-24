import ComposableArchitecture
import Foundation
import Testing
@testable import CodexWorker

@MainActor
struct ChatFeatureEventTests {
    @Test
    func liveDeltaDoesNotRenderPartialMessageBeforeCompletion() async {
        var initialState = ChatFeature.State()
        initialState.currentJobId = "job_live_delta_1"
        let store = TestStore(initialState: initialState) {
            ChatFeature()
        }
        store.exhaustivity = .off

        let deltaEnvelope = EventEnvelope(
            type: EventType.itemAgentMessageDelta.rawValue,
            ts: "2026-02-17T00:00:00.000Z",
            jobId: "job_live_delta_1",
            seq: 1,
            payload: [
                "itemId": .string("assistant_item_delta"),
                "delta": .string("hello"),
            ]
        )

        await store.send(.streamEventReceived(deltaEnvelope))

        #expect(store.state.messages.isEmpty)
        #expect(store.state.pendingAssistantDeltas["assistant_item_delta"]?.text == "hello")

        let completedEnvelope = EventEnvelope(
            type: EventType.itemCompleted.rawValue,
            ts: "2026-02-17T00:00:01.000Z",
            jobId: "job_live_delta_1",
            seq: 2,
            payload: [
                "item": .object([
                    "id": .string("assistant_item_delta"),
                    "type": .string("agentMessage"),
                ]),
            ]
        )

        await store.send(.streamEventReceived(completedEnvelope))

        #expect(store.state.messages.count == 1)
        #expect(store.state.messages.first?.id == "assistant_item_delta")
        #expect(store.state.messages.first?.text == "hello")
        #expect(store.state.pendingAssistantDeltas.isEmpty)
    }

    @Test
    func jobFinishedFlushesPendingAssistantDelta() async {
        var initialState = ChatFeature.State()
        initialState.currentJobId = "job_live_finish_1"
        let store = TestStore(initialState: initialState) {
            ChatFeature()
        }
        store.exhaustivity = .off

        let deltaEnvelope = EventEnvelope(
            type: EventType.itemAgentMessageDelta.rawValue,
            ts: "2026-02-17T00:00:00.000Z",
            jobId: "job_live_finish_1",
            seq: 1,
            payload: [
                "itemId": .string("assistant_item_finish"),
                "delta": .string("finalized by job.finished"),
            ]
        )

        await store.send(.streamEventReceived(deltaEnvelope))
        #expect(store.state.messages.isEmpty)

        let finishedEnvelope = EventEnvelope(
            type: EventType.jobFinished.rawValue,
            ts: "2026-02-17T00:00:01.000Z",
            jobId: "job_live_finish_1",
            seq: 2,
            payload: [
                "state": .string("DONE"),
            ]
        )

        await store.send(.streamEventReceived(finishedEnvelope))

        #expect(store.state.messages.count == 1)
        #expect(store.state.messages.first?.id == "assistant_item_finish")
        #expect(store.state.messages.first?.text == "finalized by job.finished")
        #expect(store.state.pendingAssistantDeltas.isEmpty)
    }

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

    @Test
    func replayApprovalRequiredEmitsDelegateForCurrentThread() async {
        let approvalPayload: [String: JSONValue] = [
            "approvalId": .string("appr_replay_1"),
            "jobId": .string("job_replay_approval_1"),
            "threadId": .string("thread_replay_approval_1"),
            "turnId": .string("turn_replay_approval_1"),
            "kind": .string("command_execution"),
            "requestMethod": .string("item/commandExecution/requestApproval"),
            "createdAt": .string("2026-02-17T00:02:00.000Z"),
            "command": .string("npm test"),
            "cwd": .string("/tmp/project"),
            "commandActions": .array([.string("run")]),
        ]
        let expectedApproval = Approval.fromPayload(approvalPayload, fallbackJobId: "job_replay_approval_1")

        var initialState = ChatFeature.State()
        initialState.activeThread = Thread(
            threadId: "thread_replay_approval_1",
            preview: nil,
            cwd: nil,
            createdAt: nil,
            updatedAt: nil,
            modelProvider: nil
        )

        let store = TestStore(initialState: initialState) {
            ChatFeature()
        } withDependencies: { dependencies in
            var apiClient = APIClient.mock
            apiClient.listEvents = { _, _ in
                EventsListResponse(data: [], nextCursor: -1, firstSeq: nil, job: nil)
            }
            dependencies.apiClient = apiClient
            dependencies.sseClient = SSEClient(
                subscribe: { _, _ in
                    AsyncStream { continuation in
                        continuation.finish()
                    }
                },
                cancel: {}
            )
        }
        store.exhaustivity = .off

        let approvalEnvelope = EventEnvelope(
            type: EventType.approvalRequired.rawValue,
            ts: "2026-02-17T00:02:00.000Z",
            jobId: "job_replay_approval_1",
            seq: 11,
            payload: approvalPayload
        )

        await store.send(
            .threadHistorySyncResponse(
                threadId: "thread_replay_approval_1",
                .success([approvalEnvelope])
            )
        )

        if let expectedApproval {
            await store.receive(.delegate(.approvalRequired(expectedApproval)))
        }
        #expect(store.state.isApprovalLocked == true)
        #expect(store.state.currentJobId == "job_replay_approval_1")
    }

    @Test
    func batchedStreamEventsApplyInOrderAndDeduplicateByCursor() async {
        var initialState = ChatFeature.State()
        initialState.currentJobId = "job_batch_1"
        let store = TestStore(initialState: initialState) {
            ChatFeature()
        }
        store.exhaustivity = .off

        let deltaEnvelope = EventEnvelope(
            type: EventType.itemAgentMessageDelta.rawValue,
            ts: "2026-02-17T00:10:00.000Z",
            jobId: "job_batch_1",
            seq: 1,
            payload: [
                "itemId": .string("assistant_batch_item"),
                "delta": .string("hello"),
            ]
        )
        let duplicatedDeltaEnvelope = EventEnvelope(
            type: EventType.itemAgentMessageDelta.rawValue,
            ts: "2026-02-17T00:10:00.100Z",
            jobId: "job_batch_1",
            seq: 1,
            payload: [
                "itemId": .string("assistant_batch_item"),
                "delta": .string("ignored"),
            ]
        )
        let completedEnvelope = EventEnvelope(
            type: EventType.itemCompleted.rawValue,
            ts: "2026-02-17T00:10:00.200Z",
            jobId: "job_batch_1",
            seq: 2,
            payload: [
                "item": .object([
                    "id": .string("assistant_batch_item"),
                    "type": .string("agentMessage"),
                ]),
            ]
        )

        await store.send(.streamEventsReceived([
            deltaEnvelope,
            duplicatedDeltaEnvelope,
            completedEnvelope,
        ]))

        #expect(store.state.cursor == 2)
        #expect(store.state.messages.count == 1)
        #expect(store.state.messages.first?.id == "assistant_batch_item")
        #expect(store.state.messages.first?.text == "hello")
        #expect(store.state.pendingAssistantDeltas.isEmpty)
    }

    @Test
    func batchedStreamEventsIgnoreDifferentJobId() async {
        var initialState = ChatFeature.State()
        initialState.currentJobId = "job_batch_target"
        let store = TestStore(initialState: initialState) {
            ChatFeature()
        }
        store.exhaustivity = .off

        let otherJobEnvelope = EventEnvelope(
            type: EventType.itemAgentMessageDelta.rawValue,
            ts: "2026-02-17T00:12:00.000Z",
            jobId: "job_batch_other",
            seq: 1,
            payload: [
                "itemId": .string("assistant_other_item"),
                "delta": .string("should be ignored"),
            ]
        )

        await store.send(.streamEventsReceived([otherJobEnvelope]))

        #expect(store.state.cursor == -1)
        #expect(store.state.messages.isEmpty)
        #expect(store.state.pendingAssistantDeltas.isEmpty)
    }
}
