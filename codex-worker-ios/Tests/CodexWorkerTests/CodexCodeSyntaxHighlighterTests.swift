import SwiftUI
import Testing
@testable import CodexWorker

struct CodexCodeSyntaxHighlighterTests {
    @Test
    func highlightsSwiftKeywordStringAndComment() {
        let highlighter = CodexCodeSyntaxHighlighter()
        let source = #"let value = "hi" // note"#

        let highlighted = highlighter.highlightAttributedCode(source, language: "swift")

        #expect(hasForegroundColor("let", in: highlighted))
        #expect(hasForegroundColor(#""hi""#, in: highlighted))
        #expect(hasForegroundColor("// note", in: highlighted))
    }

    @Test
    func highlightsShellCommandAndComment() {
        let highlighter = CodexCodeSyntaxHighlighter()
        let source = "ls -la # list files"

        let highlighted = highlighter.highlightAttributedCode(source, language: "bash")

        #expect(hasForegroundColor("ls", in: highlighted))
        #expect(hasForegroundColor("# list files", in: highlighted))
    }

    private func hasForegroundColor(_ token: String, in attributed: AttributedString) -> Bool {
        let plain = String(attributed.characters)
        guard
            let sourceRange = plain.range(of: token),
            let attrRange = Range(sourceRange, in: attributed),
            let run = attributed[attrRange].runs.first
        else {
            return false
        }
        return run.foregroundColor != nil
    }
}
