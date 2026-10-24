import MarkdownUI
import Testing
@testable import CodexWorker

struct ChineseMarkdownLabelTests {
    @Test
    func realChineseSummaryLabelsRenderAsStrongText() {
        let cases = [
            ("**重要代理决策：**沿用现有任务。", "重要代理决策", "沿用现有任务。"),
            ("**仍需 Human 决定：**无新增事项。", "仍需 Human 决定", "无新增事项。"),
        ]
        for (raw, label, body) in cases {
            let rendered = MessageRenderPipeline.live.render(raw).markdownContent
            #expect(rendered.renderHTML() == "<p><strong>\(label)</strong>：\(body)</p>\n")
            #expect(rendered.renderPlainText() == "\(label)：\(body)")
        }
    }

    @Test
    func codeLiteralAndAlreadyValidMarkupKeepTheirMeaning() {
        let cases = [
            "**正常加粗** 后续文字。",
            "**重要代理决策：** 沿用现有任务。",
            "`**重要代理决策：**沿用`",
            "``代码\n**重要代理决策：**沿用\n代码``",
            "```markdown\n**重要代理决策：**沿用\n```",
            "~~~markdown\n**重要代理决策：**沿用\n~~~",
            "    **重要代理决策：**沿用",
            #"\*\*重要代理决策：\*\*沿用"#,
            "[**重要代理决策：**沿用](https://example.com)",
        ]
        for raw in cases {
            #expect(MessageRenderPipeline.live.render(raw).markdownContent.renderHTML() == MarkdownContent(raw).renderHTML())
        }
    }

    @Test
    func unicodeWhitespaceCannotSplitOrCloseCode() {
        let masterCases = [
            "`open\n\u{00A0}\n**标签：**正文\n\u{00A0}\nclose`",
            "```text\n```\u{00A0}\n**标签：**正文\n```",
        ]
        let label = "**重要代理决策：**沿用"
        let inlineCases = ["\u{00A0}", "\u{2003}"].map {
            "`开始\n\($0)\n\(label)\n\($0)\n结束`"
        }
        let fenceCases = ["\u{00A0}", "\u{0085}", "\u{2028}"].map {
            "```\n示例\n```\($0)\n\(label)\n```"
        }
        for raw in masterCases + inlineCases + fenceCases {
            #expect(MessageRenderPipeline.live.render(raw).markdownContent.renderHTML() == MarkdownContent(raw).renderHTML())
        }
    }

    @Test
    func validFencesStillAllowFollowingLabelsToRender() {
        let expected = MarkdownContent("```md\n**重要代理决策：**沿用\n```\n\n**仍需 Human 决定**：无新增事项。").renderHTML()
        for ending in ["\n", "\r\n", "\r"] {
            let raw = ["```md", "**重要代理决策：**沿用", "```", "", "**仍需 Human 决定：**无新增事项。"].joined(separator: ending)
            #expect(MessageRenderPipeline.live.render(raw).markdownContent.renderHTML() == expected)
        }
    }
}
