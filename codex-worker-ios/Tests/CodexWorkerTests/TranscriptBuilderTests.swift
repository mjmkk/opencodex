import Foundation
import XCTest

@testable import CodexWorker

/// AGT-26 S6：线程页统一消息模型
final class TranscriptBuilderTests: XCTestCase {
    /// 用 /v1/harness/thread 返回的真实 Claude 会话做样本（截取前 3 个 turn，文本截断）
    func testClaudeRealPayloadDecodes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "harness-thread-claude", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let t = try TranscriptBuilder.claude(payload)
        XCTAssertEqual(t.model, "claude-opus-5-5")
        XCTAssertFalse(t.rows.isEmpty)
        guard case .user = t.rows[0].kind else { return XCTFail("第一行应该是用户消息") }
        XCTAssertNotNil(t.rows[0].at, "ISO 8601 带毫秒的时间要能解析")
    }

    /// 一个 turn 里只有最后一条 assistant 是回答，前面的都折叠成“中间过程”
    func testClaudeFoldsIntermediateAssistantMessages() throws {
        let payload: JSONValue = .object(["ok": .bool(true), "thread": .object(["turns": .array([
            .object(["items": .array([
                .object(["role": .string("user"), "text": .string("问")]),
                .object(["role": .string("assistant"), "text": .string("我先查一下")]),
                .object(["role": .string("assistant"), "text": .string("再看一个文件")]),
                .object(["role": .string("assistant"), "text": .string("结论")]),
            ])]),
        ])])])
        let kinds = try TranscriptBuilder.claude(payload).rows.map(\.kind)
        XCTAssertEqual(kinds, [.user("问"), .folded(count: 2, kinds: ["过程"]), .assistant("结论")])
    }

    /// Codex：两条用户消息之间只留最后一条 assistant，文本去掉首尾空白，空消息跳过
    func testCodexFoldsPerTurnAndTrims() {
        func msg(_ id: String, _ role: String, _ text: String) -> ThreadHistory.Message {
            .init(id: id, role: role, text: text, sentAt: nil)
        }
        let history = ThreadHistory(threadIdentity: "x", messages: [
            msg("1", "user", "问\n"), msg("2", "assistant", "查一下"), msg("3", "assistant", "  "),
            msg("4", "assistant", "结论\n"), msg("5", "user", "再问"), msg("6", "assistant", "好"),
        ], records: [], attachments: [], downloadedAt: Date(), isPartial: false, hasMore: false,
           availableMessageCount: 6, refreshRequested: false)
        XCTAssertEqual(TranscriptBuilder.codex(history).rows.map(\.kind),
                       [.user("问"), .folded(count: 1, kinds: ["过程"]), .assistant("结论"), .user("再问"), .assistant("好")])
    }

    func testClaudeRejectsErrorPayload() {
        XCTAssertThrowsError(try TranscriptBuilder.claude(.object(["ok": .bool(false), "error": .string("use_mirror")])))
    }
}
