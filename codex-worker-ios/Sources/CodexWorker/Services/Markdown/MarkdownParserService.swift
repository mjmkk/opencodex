//
//  MarkdownParserService.swift
//  CodexWorker
//
//  Markdown 解析服务：负责将消息文本转换为 AttributedString，并在失败时回退纯文本。
//

import Foundation
import MarkdownUI

public struct MarkdownParseResult: Equatable {
    public let markdownContent: MarkdownContent
    public let usedFallback: Bool
    public let fallbackReason: String?

    public init(
        markdownContent: MarkdownContent,
        usedFallback: Bool,
        fallbackReason: String? = nil
    ) {
        self.markdownContent = markdownContent
        self.usedFallback = usedFallback
        self.fallbackReason = fallbackReason
    }
}

public struct MarkdownParserService: Sendable {
    public static let live = MarkdownParserService()

    private let parseMarkdown: @Sendable (_ raw: String) throws -> MarkdownContent

    public init(
        parseMarkdown: @escaping @Sendable (_ raw: String) throws -> MarkdownContent = { raw in
            MarkdownContent(raw)
        }
    ) {
        self.parseMarkdown = parseMarkdown
    }

    public func parse(_ raw: String) -> MarkdownParseResult {
        guard !raw.isEmpty else {
            return MarkdownParseResult(
                markdownContent: MarkdownContent(""),
                usedFallback: false
            )
        }

        do {
            let content = try parseMarkdown(raw)
            return MarkdownParseResult(
                markdownContent: content,
                usedFallback: false
            )
        } catch {
            return MarkdownParseResult(
                markdownContent: MarkdownContent(raw),
                usedFallback: true,
                fallbackReason: String(describing: error)
            )
        }
    }
}
