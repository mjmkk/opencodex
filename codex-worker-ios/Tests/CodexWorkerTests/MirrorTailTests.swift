import Foundation
import XCTest

@testable import CodexWorker

/// AGT-26 S6：打开线程只拉最新一段，和本地缓存拼接；“加载更早”往前补
final class MirrorTailTests: XCTestCase {
    let ns = "openai:test", tid = "t1", scope = "s:mirror:openai:test"

    /// 模拟服务端：线程共 total 条消息 m0…m(total-1)
    func server(_ total: Int) -> @Sendable (Bool, Int?, Int) async throws -> MirrorBody {
        let ns = ns, tid = tid
        return { _, offset, limit in
            let start = offset ?? max(0, total - limit)
            let end = min(total, start + limit)
            return MirrorBody(ok: true, namespace: ns, source: "local_mirror",
                thread: MirrorThread(thread_id: tid, namespace: ns),
                messages: (start..<end).map { MirrorMessage(native_id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text_content: "x\($0)") },
                items: [MirrorItem(native_id: "i0")], attachments: [],
                page: MirrorPage(offset: start, limit: limit, local_total: total, snapshot: "s\(total)",
                                 next_offset: end < total ? end : nil, scope: "local_only"))
        }
    }

    func cache() throws -> MobileSyncCache {
        try MobileSyncCache(path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path)
    }

    func testTailThenEarlierThenNewMessages() async throws {
        let c = try cache()
        // 第一次打开：只拿最新 200 条
        var b = try await MirrorHistoryReader.syncTail(tid, namespace: ns, scope: scope, cache: c, offline: true, readWindow: server(450))
        XCTAssertEqual(b.messages.map(\.native_id).first, "m250")
        XCTAssertEqual(b.messages.count, 200)
        XCTAssertEqual(b.page.offset, 250)
        XCTAssertTrue(b.items.isEmpty)
        var h = try await XCTUnwrapAsync(await c.mirrorBody(tid, scope: scope)).history
        XCTAssertTrue(h.hasMore)

        // 往前补两次，直到最早一条
        _ = try await MirrorHistoryReader.loadEarlier(tid, namespace: ns, scope: scope, cache: c, readWindow: server(450))
        b = try await MirrorHistoryReader.loadEarlier(tid, namespace: ns, scope: scope, cache: c, readWindow: server(450))!
        XCTAssertEqual(b.messages.count, 450)
        XCTAssertEqual(b.messages.first?.native_id, "m0")
        XCTAssertEqual(Set(b.messages.map(\.native_id)).count, 450)
        h = try await XCTUnwrapAsync(await c.mirrorBody(tid, scope: scope)).history
        XCTAssertFalse(h.hasMore)
        let none = try await MirrorHistoryReader.loadEarlier(tid, namespace: ns, scope: scope, cache: c, readWindow: server(450))
        XCTAssertNil(none)

        // 线程又多了 30 条：再次打开只拉最新 200 条，已经翻过的更早消息保留
        b = try await MirrorHistoryReader.syncTail(tid, namespace: ns, scope: scope, cache: c, offline: true, readWindow: server(480))
        XCTAssertEqual(b.messages.count, 480)
        XCTAssertEqual(b.messages.first?.native_id, "m0")
        XCTAssertEqual(b.messages.last?.native_id, "m479")
        XCTAssertEqual(b.page.offset, 0)
        XCTAssertEqual(Set(b.messages.map(\.native_id)).count, 480)
    }

    func testGapTooLargeKeepsOnlyFreshWindow() async throws {
        let c = try cache()
        _ = try await MirrorHistoryReader.syncTail(tid, namespace: ns, scope: scope, cache: c, offline: true, readWindow: server(100))
        // 离开期间多了 500 条，新窗口和缓存接不上：只留新窗口，往前还能补
        let b = try await MirrorHistoryReader.syncTail(tid, namespace: ns, scope: scope, cache: c, offline: true, readWindow: server(600))
        XCTAssertEqual(b.messages.first?.native_id, "m400")
        XCTAssertEqual(b.messages.count, 200)
        XCTAssertEqual(b.page.offset, 400)
    }

    func testEmptyServerResultKeepsCache() async throws {
        let c = try cache()
        _ = try await MirrorHistoryReader.syncTail(tid, namespace: ns, scope: scope, cache: c, offline: true, readWindow: server(50))
        let b = try await MirrorHistoryReader.syncTail(tid, namespace: ns, scope: scope, cache: c, offline: false, readWindow: server(0))
        XCTAssertEqual(b.messages.count, 50)
    }

    private func XCTUnwrapAsync<T>(_ v: T?) throws -> T { try XCTUnwrap(v) }
}
