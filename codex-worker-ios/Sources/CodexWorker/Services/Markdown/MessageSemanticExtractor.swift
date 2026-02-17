//
//  MessageSemanticExtractor.swift
//  CodexWorker
//
//  Markdown 语义提取器：识别消息中的结构化信息，供渲染层和后续交互能力使用。
//

import Foundation

public enum UnsupportedMarkdownFeature: String, CaseIterable, Sendable {
    case htmlBlock
    case latexMath

    public var displayName: String {
        switch self {
        case .htmlBlock:
            return "HTML"
        case .latexMath:
            return "数学公式"
        }
    }
}

public struct MessageSemanticSnapshot: Equatable, Sendable {
    public var hasHeading: Bool
    public var hasList: Bool
    public var hasBlockQuote: Bool
    public var hasCodeBlock: Bool
    public var hasInlineCode: Bool
    public var hasTable: Bool
    public var hasTaskList: Bool
    public var links: [String]
    public var pathHints: [String]
    public var commandHints: [String]
    public var unsupportedFeatures: Set<UnsupportedMarkdownFeature>

    public init(
        hasHeading: Bool = false,
        hasList: Bool = false,
        hasBlockQuote: Bool = false,
        hasCodeBlock: Bool = false,
        hasInlineCode: Bool = false,
        hasTable: Bool = false,
        hasTaskList: Bool = false,
        links: [String] = [],
        pathHints: [String] = [],
        commandHints: [String] = [],
        unsupportedFeatures: Set<UnsupportedMarkdownFeature> = []
    ) {
        self.hasHeading = hasHeading
        self.hasList = hasList
        self.hasBlockQuote = hasBlockQuote
        self.hasCodeBlock = hasCodeBlock
        self.hasInlineCode = hasInlineCode
        self.hasTable = hasTable
        self.hasTaskList = hasTaskList
        self.links = links
        self.pathHints = pathHints
        self.commandHints = commandHints
        self.unsupportedFeatures = unsupportedFeatures
    }
}

public struct MessageSemanticExtractor: Sendable {
    public static let live = MessageSemanticExtractor()

    private let shellLanguages: Set<String> = ["bash", "zsh", "sh", "shell", "console"]

    public init() {}

    public func extract(from raw: String) -> MessageSemanticSnapshot {
        guard !raw.isEmpty else { return MessageSemanticSnapshot() }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var snapshot = MessageSemanticSnapshot()
        var commandHints = Set<String>()

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                snapshot.hasCodeBlock = true
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let isShellBlock = shellLanguages.contains(language)

                index += 1
                while index < lines.count {
                    let codeLine = lines[index]
                    let codeTrimmed = codeLine.trimmingCharacters(in: .whitespaces)
                    if codeTrimmed.hasPrefix("```") {
                        break
                    }
                    if isShellBlock, !codeTrimmed.isEmpty, !codeTrimmed.hasPrefix("#") {
                        commandHints.insert(codeTrimmed)
                    }
                    index += 1
                }
                index += 1
                continue
            }

            if matches(trimmed, pattern: #"^\s{0,3}#{1,6}\s+"#) {
                snapshot.hasHeading = true
            }

            if matches(trimmed, pattern: #"^\s*(?:[-*+]|\d+\.)\s+"#) {
                snapshot.hasList = true
            }

            if matches(trimmed, pattern: #"^\s*>\s?"#) {
                snapshot.hasBlockQuote = true
            }

            if matches(trimmed, pattern: #"^\s*[-*+]\s+\[[ xX]\]\s+"#) {
                snapshot.hasList = true
                snapshot.hasTaskList = true
            }

            if tickCount(in: trimmed) >= 2 {
                snapshot.hasInlineCode = true
            }

            if matches(trimmed, pattern: #"<[A-Za-z][^>]*>"#) {
                snapshot.unsupportedFeatures.insert(.htmlBlock)
            }

            if matches(trimmed, pattern: #"\$\$[^$]+\$\$|\$[^$\n]+\$"#) {
                snapshot.unsupportedFeatures.insert(.latexMath)
            }

            if isLikelyTableHeader(
                headerLine: line,
                separatorLine: index + 1 < lines.count ? lines[index + 1] : nil
            ) {
                snapshot.hasTable = true
            }

            index += 1
        }

        snapshot.links = extractMatches(
            in: raw,
            pattern: #"https?://[^\s<>()]+"#
        )

        let absolutePaths = extractMatches(
            in: raw,
            pattern: #"(?:(?<=\s)|(?<=[：:])|^)(/[A-Za-z0-9._~\-]+(?:/[A-Za-z0-9._~\-]+)+)"#,
            captureGroup: 1
        )
        let relativePaths = extractMatches(
            in: raw,
            pattern: #"(?:(?<=\s)|(?<=[：:])|^)((?:\./|\.\./)[A-Za-z0-9._~\-/]+)"#,
            captureGroup: 1
        )
        snapshot.pathHints = Array(Set(absolutePaths + relativePaths)).sorted()

        snapshot.commandHints = Array(commandHints).sorted()
        return snapshot
    }

    private func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func tickCount(in text: String) -> Int {
        text.filter { $0 == "`" }.count
    }

    private func isLikelyTableHeader(headerLine: String, separatorLine: String?) -> Bool {
        guard let separatorLine, headerLine.contains("|") else { return false }
        let trimmedSeparator = separatorLine.trimmingCharacters(in: .whitespaces)
        return matches(
            trimmedSeparator,
            pattern: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#
        )
    }

    private func extractMatches(
        in text: String,
        pattern: String,
        captureGroup: Int = 0
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)

        let values: [String] = regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: captureGroup), in: text) else { return nil }
            return String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        }
        return Array(Set(values)).sorted()
    }
}
