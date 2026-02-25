import Foundation
import Testing
@testable import CodexWorker

struct MessageLinkNormalizerTests {
    @Test
    func convertsFileReferenceAndUrlToMarkdownLinks() {
        let input = "请看 codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438 和 https://example.com/docs"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output.contains("[codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438](codexfs://open?ref="))
        #expect(output.contains("[https://example.com/docs](https://example.com/docs)"))
    }

    @Test
    func keepsCodeBlockUntouched() {
        let input = """
        ```
        codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438
        https://example.com/docs
        ```
        """
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output.contains("codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438"))
        #expect(!output.contains("codexfs://open"))
        #expect(!output.contains("[https://example.com/docs](https://example.com/docs)"))
    }

    @Test
    func convertsBacktickedFileReferenceToClickableLink() {
        let input = "请查看 `codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438`"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output.contains("[codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438](codexfs://open?ref="))
        #expect(!output.contains("`codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438`"))
    }

    @Test
    func keepsExistingMarkdownLinkWithoutDoubleWrapping() {
        let input = "[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)"
        let output = MessageLinkNormalizer.live.normalize(input)
        let expected = "[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=%2FUsers%2FApple%2FDev%2FOpenCodex%2FREADME.md)"

        #expect(output == expected)
        #expect(!output.contains("[[/Users/Apple"))
    }

    @Test
    func collapsesNestedMarkdownLinkFromLegacyContent() {
        let input = "[[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)"
        let output = MessageLinkNormalizer.live.normalize(input)
        let expected = "[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=%2FUsers%2FApple%2FDev%2FOpenCodex%2FREADME.md)"

        #expect(output == expected)
    }

    @Test
    func collapsesNestedMarkdownLinkEvenWhenOuterUrlDiffers() {
        let input = "[[README.md](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)](https://example.com/legacy-wrapper)"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output == "[README.md](codexfs://open?ref=%2FUsers%2FApple%2FDev%2FOpenCodex%2FREADME.md)")
    }

    @Test
    func codexFileLinkQueryIsPercentEncodedAndReversible() {
        let input = "请看 /Users/Apple/Dev/OpenCodex/codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438"
        let output = MessageLinkNormalizer.live.normalize(input)

        let prefix = "(codexfs://open?ref="
        guard
            let start = output.range(of: prefix),
            let end = output[start.upperBound...].firstIndex(of: ")")
        else {
            Issue.record("未找到 codexfs 链接")
            return
        }
        let encodedURL = String(output[start.upperBound..<end])

        #expect(encodedURL.contains("%2F"))

        guard let components = URLComponents(string: "codexfs://open?ref=\(encodedURL)") else {
            Issue.record("无法解析 codexfs URL")
            return
        }
        let ref = components.queryItems?.first(where: { $0.name == "ref" })?.value
        #expect(ref == "/Users/Apple/Dev/OpenCodex/codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438")
    }

    @Test
    func upgradesExistingUnencodedCodexFsMarkdownLink() {
        let input = "[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output.contains("(codexfs://open?ref=%2FUsers%2FApple%2FDev%2FOpenCodex%2FREADME.md)"))
    }

    @Test
    func stripsBackticksInsideExistingCodexFsMarkdownLabel() {
        let input = "[`/Users/Apple/Dev/OpenCodex/README.md`](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(!output.contains("`/Users/Apple/Dev/OpenCodex/README.md`"))
        #expect(output.contains("[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=%2FUsers%2FApple%2FDev%2FOpenCodex%2FREADME.md)"))
    }

    @Test
    func unwrapsBacktickedMarkdownCodexFsLinkToClickableLink() {
        let input = "`[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=/Users/Apple/Dev/OpenCodex/README.md)`"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(!output.hasPrefix("`"))
        #expect(!output.hasSuffix("`"))
        #expect(output == "[/Users/Apple/Dev/OpenCodex/README.md](codexfs://open?ref=%2FUsers%2FApple%2FDev%2FOpenCodex%2FREADME.md)")
    }

    @Test
    func unwrapsBacktickedHttpUrlToClickableLinkWithoutPercent60() {
        let input = "`https://github.com/simonbs/Runestone`"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output == "[https://github.com/simonbs/Runestone](https://github.com/simonbs/Runestone)")
        #expect(!output.contains("%60"))
    }

    @Test
    func stripsTrailingBacktickFromHttpUrlTarget() {
        let input = "参考 https://github.com/simonbs/Runestone`"
        let output = MessageLinkNormalizer.live.normalize(input)

        #expect(output.contains("[https://github.com/simonbs/Runestone](https://github.com/simonbs/Runestone)"))
        #expect(!output.contains("Runestone%60"))
    }
}
