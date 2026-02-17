import Foundation
import Testing
@testable import CodexWorker

private struct ForcedParseFailure: Error {}

struct MarkdownParserServiceTests {
    @Test
    func parserReturnsMarkdownContentWhenSuccessful() {
        let result = MarkdownParserService.live.parse("**Hello** `Codex`")

        #expect(result.usedFallback == false)
        #expect(result.fallbackReason == nil)
    }

    @Test
    func parserFallsBackToPlainTextWhenParserThrows() {
        let service = MarkdownParserService(
            parseMarkdown: { _ in
                throw ForcedParseFailure()
            }
        )

        let raw = "**fallback** text"
        let result = service.parse(raw)

        #expect(result.usedFallback)
        #expect(result.fallbackReason != nil)
    }
}
