import Foundation
import Testing
@testable import CodexWorker

/// Codec, identity guards and real isolated GRDB only; no API or AI stub.
struct NativeControlExecutionTests {
    private let threadID = "00000000-0000-4000-8000-000000000001"
    private let namespace = "schema-only-source"

    private func thread() -> CodexWorker.Thread {
        var value = CodexWorker.Thread(threadId: threadID, preview: nil, cwd: nil,
            createdAt: nil, updatedAt: nil, modelProvider: nil)
        value.origin = .init(namespace: namespace, hostID: "mirror-origin-does-not-grant-control")
        return value
    }

    private func observation() -> NativeControlObservation {
        .init(thread_id: threadID, host_id: "remote-control:schema-only-machine", owner_client_id: "schema-owner",
            protocol: "plain-text-ssh-v1", status: "idle", reply_route: "start", input_available: true,
            stop_available: false, control_receipt: String(repeating: "a", count: 64),
            control_version: String(repeating: "b", count: 64),
            steer_semantics: "current-task-may-follow-new-active-turn", stop_mode: "user-stop",
            stop_pauses_goal: false, stop_may_interrupt_active_thread_descendants: true,
            native_host_id: "local", source_namespace: namespace, execution_machine: "schema-only-machine",
            execution_binding: String(repeating: "c", count: 64))
    }

    private func receipt(_ context: NativeControlExecutionContext) -> NativeControlReceipt {
        .init(submission_id: "schema-submission", thread_id: threadID, operation: "start", status: "accepted",
            turn_id: "schema-turn", protocol: context.protocolName, host_id: context.hostID,
            native_host_id: context.nativeHostID, source_namespace: context.sourceNamespace,
            execution_machine: context.machine, execution_binding: context.binding)
    }

    @Test
    func sshControlRequiresSelectedNamespaceAndCompleteExecutionIdentity() {
        let shown = observation()
        #expect(shown.validates(thread: thread()))
        #expect(!shown.validates(threadID: threadID)) // Old local-only guard stays strict.
        #expect(!shown.canStop)
        var wrong = shown
        wrong.source_namespace = "another-source"
        #expect(!wrong.validates(thread: thread()))
        wrong = shown; wrong.native_host_id = "another-native-host"
        #expect(!wrong.validates(thread: thread()))
        wrong = shown; wrong.execution_binding = nil
        #expect(!wrong.validates(thread: thread()))
        wrong = shown; wrong.execution_binding = String(repeating: "z", count: 64)
        #expect(!wrong.validates(thread: thread()))
        wrong = shown; wrong.stop_available = true
        #expect(!wrong.validates(thread: thread()))
    }

    @Test
    func receiptMustMatchTheSealedExecutionContext() throws {
        let context = try #require(observation().executionContext)
        let attempt = NativeControlAttempt(operation: .input,
            request: .init(submission_id: "schema-submission", control_receipt: "receipt", control_version: "version", text: "正文"),
            attemptedAt: Date(), executionContext: context, accountScope: "schema-account")
        let accepted = receipt(context)
        #expect(attempt.validates(accepted, threadID: threadID))
        var wrong = accepted
        wrong.host_id = "another-machine"
        #expect(!attempt.validates(wrong, threadID: threadID))
        wrong = accepted; wrong.source_namespace = "another-source"
        #expect(!attempt.validates(wrong, threadID: threadID))
        wrong = accepted; wrong.execution_binding = String(repeating: "d", count: 64)
        #expect(!attempt.validates(wrong, threadID: threadID))
        wrong = accepted; wrong.native_host_id = nil
        #expect(!attempt.validates(wrong, threadID: threadID))
    }

    @Test
    func legacyIntentStillDecodesAndCannotAcquireRemoteIdentity() throws {
        let bytes = Data(#"{"operation":"input","request":{"submission_id":"schema-submission","control_receipt":"receipt","control_version":"version","text":"正文"},"attemptedAt":1}"#.utf8)
        let legacy = try JSONDecoder().decode(NativeControlAttempt.self, from: bytes)
        #expect(legacy.executionContext == nil && legacy.accountScope == nil && legacy.isUncertain)
        let local = NativeControlReceipt(submission_id: "schema-submission", thread_id: threadID,
            operation: "start", status: "accepted", turn_id: "schema-turn")
        #expect(legacy.validates(local, threadID: threadID))
        #expect(!legacy.validates(receipt(try #require(observation().executionContext)), threadID: threadID))
    }

    @Test
    func remoteIntentPersistsBindingAndAcceptancePreservesNewerDraft() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let context = try #require(observation().executionContext)
        let attempt = NativeControlAttempt(operation: .input,
            request: .init(submission_id: "schema-submission", control_receipt: "receipt", control_version: "version", text: "原文"),
            attemptedAt: Date(), executionContext: context, accountScope: "schema-account")
        let first = try MobileSyncCache(path: path)
        _ = try await first.beginControlAttempt(attempt, text: "原文", threadId: threadID, scope: "schema-account")
        let reopened = try MobileSyncCache(path: path)
        let restored = try #require(try await reopened.composer(threadId: threadID, scope: "schema-account"))
        #expect(restored.controlAttempt?.executionContext == context)
        #expect(restored.controlAttempt?.accountScope == "schema-account")
        try await reopened.saveComposer(.init(text: "后续新草稿"), threadId: threadID, scope: "schema-account")
        let result = try await reopened.reconcileControlAttempt(id: "schema-submission", receipt: receipt(context),
            threadId: threadID, scope: "schema-account")
        #expect(result.text == "后续新草稿")
        #expect(result.controlAttempt?.receipt?.status == "accepted")
        #expect(result.controlAttempt?.executionContext == context)
    }
}
