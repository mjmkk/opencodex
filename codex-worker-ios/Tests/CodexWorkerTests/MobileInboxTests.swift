import Foundation
import Testing
@testable import CodexWorker

struct MobileInboxTests {
    private func approval(_ id: String, context: String = "v2", risk: String = "ordinary") -> MobileApproval {
        .init(request: ["id": .string(id), "context_version": .string(context), "expires_at": .double(Date().addingTimeInterval(3600).timeIntervalSince1970),
                        "risk": .string(risk), "batch_scope": .string("one-operation"), "return_target": .object(["thread_id": .string("original")])],
              request_version: "request-v1", state: "pending")
    }

    @Test func batchRequiresCurrentRequestsOneContextAndExplicitOrdinaryScope() {
        var state = MobileInboxFeature.State()
        state.items = [approval("a"), approval("b")]; state.selected = ["a", "b"]
        for id in ["a", "b"] { state.drafts[id] = .init(requestVersion: "request-v1", eventId: id, value: .bool(true)) }
        #expect(state.batchScope == "one-operation")
        state.items[1] = approval("b", context: "old"); #expect(state.batchScope == nil)
        state.items[1] = approval("b", risk: "high"); #expect(state.batchScope == nil)
        state.items[1] = approval("b"); state.drafts["b"]?.requestVersion = "old"; #expect(state.batchScope == nil)
    }

    @Test func offlineDraftPersistsItsNonceWithoutClaimingApproval() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let cache = try MobileSyncCache(path: path)
        try await cache.saveApprovals([approval("a")], scope: "account")
        let draft = MobileApprovalDraft(requestVersion: "request-v1", eventId: "immutable-retry-id", value: .object(["note": .string("离线草稿")]))
        try await cache.saveApprovalDraft(draft, id: "a", scope: "account")
        let reopened = try MobileSyncCache(path: path)
        let (items, drafts) = try await reopened.approvals(scope: "account")
        #expect(items[0].state == "pending"); #expect(items[0].statusText == "等待你确认")
        #expect(drafts["a"] == draft)
        #expect(try await reopened.approvals(scope: "another").0.isEmpty)
    }

    @Test func executionActivityConvergesWithoutDuplicatingChat() {
        let events = ["item.started", "item.completed"].map {
            EventEnvelope(type: $0, ts: "2026-09-15T00:00:00Z", jobId: "job", seq: 0,
                          payload: ["item": .object(["type": .string("commandExecution"), "id": .string("command")])])
        }
        let items = ThreadActivityItem.collect(events)
        #expect(items.count == 1); #expect(items[0].event.type == "item.completed")
    }
}
