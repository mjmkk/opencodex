//
//  MessageRenderPipeline.swift
//  CodexWorker
//
//  消息渲染管线：将文本解析与语义提取收敛到统一入口，供 UI 层直接消费。
//

import Foundation
import MarkdownUI

public struct MessageRenderContent: Equatable {
    public let markdownContent: MarkdownContent
    public let semantics: MessageSemanticSnapshot
    public let usedMarkdownFallback: Bool
    public let fallbackReason: String?

    public init(
        markdownContent: MarkdownContent,
        semantics: MessageSemanticSnapshot,
        usedMarkdownFallback: Bool,
        fallbackReason: String?
    ) {
        self.markdownContent = markdownContent
        self.semantics = semantics
        self.usedMarkdownFallback = usedMarkdownFallback
        self.fallbackReason = fallbackReason
    }

    public var compatibilityHint: String? {
        usedMarkdownFallback ? "Markdown 解析失败，已降级为纯文本显示" : nil
    }
}

public struct MessageRenderPipeline: Sendable {
    public static let live = MessageRenderPipeline()
    private static let cacheVersion = "v4"

    private let parser: MarkdownParserService
    private let semanticExtractor: MessageSemanticExtractor
    private let linkNormalizer: MessageLinkNormalizer
    private let cache: MarkdownRenderCache

    init(
        parser: MarkdownParserService = .live,
        semanticExtractor: MessageSemanticExtractor = .live,
        linkNormalizer: MessageLinkNormalizer = .live,
        cache: MarkdownRenderCache = .shared
    ) {
        self.parser = parser
        self.semanticExtractor = semanticExtractor
        self.linkNormalizer = linkNormalizer
        self.cache = cache
    }

    public func render(_ raw: String) -> MessageRenderContent {
        let cacheKey = "\(Self.cacheVersion)::\(raw)"
        if let cached = cache.value(for: cacheKey) {
            return cached
        }

        let normalized = linkNormalizer.normalize(ChineseMarkdownLabels.normalize(raw))
        let parseResult = parser.parse(normalized)
        let semantics = semanticExtractor.extract(from: raw)
        let content = MessageRenderContent(
            markdownContent: parseResult.markdownContent,
            semantics: semantics,
            usedMarkdownFallback: parseResult.usedFallback,
            fallbackReason: parseResult.fallbackReason
        )
        cache.insert(content, for: cacheKey)
        return content
    }

    func clearCache() {
        cache.clear()
    }
}

private enum ChineseMarkdownLabels {
    private static let labelPattern = try? NSRegularExpression(
        pattern: #"^\*\*([\p{L}\p{N} ]{1,64})：\*\*(?=\p{Han})"#
    )
    private static let fencePattern = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)

    static func normalize(_ raw: String) -> String {
        // Only repair plain paragraph labels in the display copy. Be conservative
        // around code, escapes, links and HTML; history and semantic input stay raw.
        guard raw.contains("：**"),
              raw.range(of: #"(?m)^ {0,3}<"#, options: .regularExpression) == nil,
              let labelPattern, let fencePattern else { return raw }
        var output: [String] = []
        var paragraph: [String] = []
        var fence: (marker: Character, count: Int)?

        func appendParagraph() {
            let text = paragraph.joined(separator: "\n")
            let protected = text.contains { "`\\[]<>".contains($0) }
            output.append(contentsOf: paragraph.map { line in
                guard !protected,
                      let match = labelPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let labelRange = Range(match.range(at: 1), in: line),
                      let fullRange = Range(match.range, in: line) else { return line }
                let label = line[labelRange]
                guard label.first?.isWhitespace == false, label.last?.isWhitespace == false,
                      label.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return line }
                return line.replacingCharacters(in: fullRange, with: "**\(label)**：")
            })
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in raw.components(separatedBy: "\n") {
            let match = fencePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            if let active = fence {
                output.append(line)
                if let match, let markerRange = Range(match.range(at: 1), in: line),
                   let tailRange = Range(match.range(at: 2), in: line) {
                    let marker = line[markerRange]
                    if marker.first == active.marker, marker.count >= active.count,
                       line[tailRange].allSatisfy(\.isWhitespace) { fence = nil }
                }
            } else if let match, let markerRange = Range(match.range(at: 1), in: line),
                      let marker = line[markerRange].first {
                appendParagraph()
                output.append(line)
                fence = (marker, line[markerRange].count)
            } else if line.allSatisfy(\.isWhitespace) {
                appendParagraph()
                output.append(line)
            } else {
                paragraph.append(line)
            }
        }
        appendParagraph()
        return output.joined(separator: "\n")
    }
}

final class MarkdownRenderCache: @unchecked Sendable {
    static let shared = MarkdownRenderCache(maxEntries: 300)

    private let lock = NSLock()
    private var storage: [String: MessageRenderContent] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries: Int

    init(maxEntries: Int) {
        self.maxEntries = max(32, maxEntries)
    }

    func value(for key: String) -> MessageRenderContent? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func insert(_ value: MessageRenderContent, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        let isNewKey = storage[key] == nil
        storage[key] = value
        if isNewKey {
            insertionOrder.append(key)
        }

        while insertionOrder.count > maxEntries {
            let removedKey = insertionOrder.removeFirst()
            storage[removedKey] = nil
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        insertionOrder.removeAll()
    }
}
