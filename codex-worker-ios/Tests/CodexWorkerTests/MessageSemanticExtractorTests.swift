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
}
