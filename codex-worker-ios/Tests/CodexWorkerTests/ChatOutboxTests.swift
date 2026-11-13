import XCTest
@testable import CodexWorker

@MainActor final class ChatOutboxTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
    }

    func testRepeatedMessagesClaimDifferentServerRecords() {
        let box = ChatOutbox(url: file())
        let old = Transcript.Row(id: "old", kind: .user("OK"), at: Date())
        XCTAssertTrue(box.enqueue("OK", rows: [old]))
        XCTAssertTrue(box.enqueue("OK", rows: [old]))
        for i in box.messages.indices { box.messages[i].tried = true }
        box.reconcile([old])
        XCTAssertTrue(box.messages.allSatisfy { $0.matchedID == nil }, "30秒内的旧消息不能隐藏新气泡")
        let one = Transcript.Row(id: "new-1", kind: .user("OK"), at: Date())
        box.reconcile([old, one])
        XCTAssertEqual(box.messages[0].matchedID, "new-1")
        XCTAssertNil(box.messages[1].matchedID, "同一条服务端消息不能认领两次")
        box.reconcile([old, one, .init(id: "new-2", kind: .user("OK"), at: Date())])
        XCTAssertEqual(box.messages[1].matchedID, "new-2")
    }

    func testRestartPreservesFailureDraftHistoryAndRoute() {
        let url = file()
        let box = ChatOutbox(url: url)
        XCTAssertTrue(box.enqueue("待重试", rows: []))
        let id = box.messages[0].id
        box.messages[0].route = .harness
        box.messages[0].tried = true
        box.messages[0].state = .failed("网络断开")
        box.draft = "还没发的草稿"
        box.remember(.init(rows: [.init(id: "reply", kind: .assistant("真实回复"), at: Date())],
                           model: nil, isPartial: false, hasMore: true))
        let restored = ChatOutbox(url: url)
        XCTAssertEqual(restored.messages[0].id, id)
        XCTAssertEqual(restored.messages[0].route, .harness)
        XCTAssertEqual(restored.messages[0].state, .failed("网络断开"))
        XCTAssertEqual(restored.draft, "还没发的草稿")
        XCTAssertEqual(restored.cached?.rows.last?.kind, .assistant("真实回复"))
    }

    func testInterruptedSendDoesNotAutomaticallyResubmit() {
        let url = file()
        let box = ChatOutbox(url: url)
        XCTAssertTrue(box.enqueue("中断", rows: []))
        box.messages[0].tried = true
        XCTAssertTrue(box.save())
        let restored = ChatOutbox(url: url)
        guard case .failed = restored.messages[0].state else { return XCTFail("结果未知的发送不能自动重发") }
        XCTAssertEqual(restored.messages[0].id, box.messages[0].id)
        XCTAssertTrue(restored.messages[0].tried)
    }
}
