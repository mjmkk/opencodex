import Foundation
import XCTest
@testable import CodexWorker

final class QuestionReplyPresentationTests: XCTestCase {
    private let opening = "<send_user_message_question_reply>"
    private let closing = "</send_user_message_question_reply>"
    private let record = #"{"questionItemId":"q1","question":"先做哪一项？","answer":"先纯重构"}"#

    private func envelope(_ payload: String) -> String { opening + "\n" + payload + "\n" + closing }

    func testExactTextAndDecodedUnicodeArePreserved() throws {
        let raw = envelope(#"[{"answer":"保留\n原文与\"引号\"\u0020\ud83d\udcf1","question":"选择\u00a0方向？","questionItemId":"q1"}]"#) + "\n"
        let formatted = try XCTUnwrap(QuestionReplyPresentation(raw, isCurrentUser: true))
        XCTAssertEqual(formatted.items, [.init(question: "选择\u{00A0}方向？", answer: "保留\n原文与\"引号\" 📱")])
        XCTAssertTrue(Array(formatted.originalText.utf8) == Array(raw.utf8))
    }

    func testMultipleAnswersKeepTheirOriginalOrder() throws {
        let second = #"{"question":"第二个问题","questionItemId":"q2","answer":"第二个回答"}"#
        let formatted = try XCTUnwrap(QuestionReplyPresentation(envelope("[" + record + "," + second + "]"), isCurrentUser: true))
        XCTAssertEqual(formatted.items.map(\.answer), ["先纯重构", "第二个回答"])
    }

    func testLiteralContextsAndMixedMessagesUseRawFallback() {
        let raw = envelope("[" + record + "]")
        let examples = [
            "```text\n" + raw + "\n```", "~~~\n" + raw + "\n~~~", "`" + raw + "`",
            "    " + raw, "\t" + raw, " " + raw, "\n" + raw, "> " + raw, "\\" + raw,
            "示例：" + raw, raw + "\n补充说明", raw + raw, raw + "\n\n", raw + " ",
            raw.replacingOccurrences(of: "<", with: "&lt;")
        ]
        for example in examples { XCTAssertNil(QuestionReplyPresentation(example, isCurrentUser: true)) }
    }

    func testUnknownIncompleteOrNonStringStructuresUseRawFallback() {
        let payloads = [
            "[]", "{}", "[null]", "[[]]", "[" + record + ",]", "[" + record + "][]",
            #"[{"questionItemId":"q1","question":"问题"}]"#,
            #"[{"questionItemId":"q1","question":"问题","answer":true}]"#,
            #"[{"questionItemId":"q1","question":"问题","answer":[]}]"#,
            #"[{"questionItemId":"q1","question":"问题","answer":"回答","state":"approved"}]"#,
            #"[{"questionItemId":"","question":"问题","answer":"回答"}]"#,
            #"[{"questionItemId":"q1","question":"","answer":"回答"}]"#,
            #"[{"questionItemId":"q1","question":"问题","answer":""}]"#,
            #"[{"questionItemId":"q1","question":"问题","answer":"坏\x转义"}]"#
        ]
        for payload in payloads { XCTAssertNil(QuestionReplyPresentation(envelope(payload), isCurrentUser: true)) }
    }

    func testDuplicateKeysCannotHideAConflictingAnswer() {
        for key in ["answer", #"\u0061nswer"#] {
            let payload = #"[{"questionItemId":"q1","question":"问题","answer":"保留",""# + key + #"":"冲突"}]"#
            XCTAssertNil(QuestionReplyPresentation(envelope(payload), isCurrentUser: true))
        }
    }

    func testRoleAndSizeLimitsFallBackWithoutTruncatingTheOriginalMessage() {
        let raw = envelope("[" + record + "]")
        XCTAssertNil(QuestionReplyPresentation(raw, isCurrentUser: false))
        XCTAssertNil(QuestionReplyPresentation(envelope("[" + Array(repeating: record, count: 17).joined(separator: ",") + "]"), isCurrentUser: true))
        let oversized = record.replacingOccurrences(of: "先纯重构", with: String(repeating: "文", count: 50_000))
        XCTAssertNil(QuestionReplyPresentation(envelope("[" + oversized + "]"), isCurrentUser: true))
    }

    func testRealSavedQuestionRepliesRetainExactOriginalAndVisibleValues() throws {
        guard let path = ProcessInfo.processInfo.environment["AGT12_REAL_QUESTION_REPLY_INPUT"] else {
            throw XCTSkip("Private real saved-message input was not provided.")
        }
        struct Input: Decodable {
            struct Entry: Decodable { let text: String; let questions: [String]; let answers: [String] }
            let messages: [Entry]
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(input.messages.count, 4)
        var allParsed = true
        var originalsMatch = true
        var visibleValuesMatch = true
        for saved in input.messages {
            guard let formatted = QuestionReplyPresentation(saved.text, isCurrentUser: true) else {
                allParsed = false
                continue
            }
            originalsMatch = originalsMatch && Array(formatted.originalText.utf8) == Array(saved.text.utf8)
            visibleValuesMatch = visibleValuesMatch
                && formatted.items.map { Array($0.question.utf8) } == saved.questions.map { Array($0.utf8) }
                && formatted.items.map { Array($0.answer.utf8) } == saved.answers.map { Array($0.utf8) }
        }
        // Only booleans enter failure output; never include private questions or answers.
        XCTAssertTrue(allParsed)
        XCTAssertTrue(originalsMatch)
        XCTAssertTrue(visibleValuesMatch)
    }
}
