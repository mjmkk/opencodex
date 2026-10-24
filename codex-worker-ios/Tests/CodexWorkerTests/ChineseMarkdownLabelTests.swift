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
}
