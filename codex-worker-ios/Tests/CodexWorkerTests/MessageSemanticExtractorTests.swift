import MarkdownUI
import Testing
@testable import CodexWorker

struct MessageSemanticExtractorTests {
    @Test
    func extractorDetectsStructuredMarkdownAndUnsupportedFeatures() {
        let markdown = """
        # 标题
        - [x] 已完成
        > 引用
        | A | B |
        | --- | --- |
        | 1 | 2 |

        ```bash
        echo hello
        ls -la
        ```

        路径：/Users/Apple/Dev/OpenCodex/README.md
        链接：https://example.com/docs
        """

        let snapshot = MessageSemanticExtractor.live.extract(from: markdown)

        #expect(snapshot.hasHeading)
        #expect(snapshot.hasList)
        #expect(snapshot.hasBlockQuote)
        #expect(snapshot.hasCodeBlock)
        #expect(snapshot.links.contains("https://example.com/docs"))
        #expect(snapshot.pathHints.contains("/Users/Apple/Dev/OpenCodex/README.md"))
        #expect(snapshot.commandHints.contains("echo hello"))
        #expect(snapshot.hasTable)
        #expect(snapshot.hasTaskList)
        #expect(snapshot.unsupportedFeatures.isEmpty)
    }

    @Test
    func renderPipelineKeepsCompatibilityHintEmptyForSupportedMarkdown() {
        let markdown = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        """

        let pipeline = MessageRenderPipeline.live
        let content = pipeline.render(markdown)

        #expect(content.compatibilityHint == nil)
        #expect(content.semantics.hasTable)
    }

    @Test
    func standaloneAssistantReferencesExplainUnavailableContentWithoutInventingIt() {
        let references = [
            #"::chatgpt-content-reference{index="1" source_message_id="5d933f4a-c93d-4343-a66a-e1a4ce43321e"}"#,
            #"::chatgpt-content-reference{index="0" source_message_id="530bed8c-ad7f-4fec-b155-61e9ac04aa3f"}"#,
        ]
        for raw in references {
            let content = MessageRenderPipeline.live.render(raw, isAssistant: true)
            #expect(content.markdownContent.renderPlainText() == "引用内容尚未展开")
            #expect(content.semantics == MessageSemanticExtractor.live.extract(from: raw))
            #expect(!content.usedMarkdownFallback)
            #expect(content.fallbackReason == nil)
            #expect(content.compatibilityHint == nil)
        }
    }

    @Test
    func literalExamplesAndMixedMessagesKeepTheirOriginalRendering() {
        let reference = #"::chatgpt-content-reference{index="1" source_message_id="5d933f4a-c93d-4343-a66a-e1a4ce43321e"}"#
        let cases = [
            "`\(reference)`", "```text\n\(reference)\n```", "~~~\n\(reference)\n~~~",
            "    \(reference)", "\t\(reference)", "\\\(reference)", "> \(reference)",
            "示例：\(reference)", "\(reference)\n后续正文", "\(reference)\n\(reference)",
            " \(reference)", "\(reference)\n", "\u{00A0}\(reference)",
            reference.replacingOccurrences(of: #"index="1""#, with: #"index="01""#),
            reference.replacingOccurrences(of: "5d933f4a", with: "not-a-uuid"),
        ]
        for raw in cases {
            #expect(MessageRenderPipeline.live.render(raw, isAssistant: true).markdownContent.renderHTML() == MarkdownContent(raw).renderHTML())
        }
    }

    @Test
    func referenceDisplayCacheSeparatesAssistantAndLiteralContextsInBothOrders() {
        let raw = #"::chatgpt-content-reference{index="1" source_message_id="5d933f4a-c93d-4343-a66a-e1a4ce43321e"}"#
        let pipeline = MessageRenderPipeline(cache: MarkdownRenderCache(maxEntries: 32))
        for order in [[true, false], [false, true]] {
            pipeline.clearCache()
            for isAssistant in order {
                let content = pipeline.render(raw, isAssistant: isAssistant)
                let expected = isAssistant ? "引用内容尚未展开" : raw
                #expect(content.markdownContent.renderHTML() == MarkdownContent(expected).renderHTML())
            }
            #expect(pipeline.render(raw).markdownContent.renderHTML() == MarkdownContent(raw).renderHTML())
        }
    }
}
