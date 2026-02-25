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
    private static let cacheVersion = "v3"

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

        let normalized = linkNormalizer.normalize(raw)
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
