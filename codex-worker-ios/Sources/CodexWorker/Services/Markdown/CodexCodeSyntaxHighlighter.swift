//
//  CodexCodeSyntaxHighlighter.swift
//  CodexWorker
//
//  Markdown 代码块语法高亮器（基于 MarkdownUI 的 CodeSyntaxHighlighter 协议）
//

import Foundation
import MarkdownUI
import SwiftUI

public struct CodexCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    public init() {}

    public func highlightCode(_ code: String, language: String?) -> Text {
        Text(highlightAttributedCode(code, language: language))
    }

    // MARK: - Internal for unit tests

    func highlightAttributedCode(_ code: String, language: String?) -> AttributedString {
        var attributed = AttributedString(code)
        guard !code.isEmpty else { return attributed }

        let normalized = normalizedLanguage(language)
        let rules = highlightRules(for: normalized)

        for rule in rules {
            apply(rule: rule, source: code, attributed: &attributed)
        }

        return attributed
    }

    // MARK: - Rule Engine

    private struct HighlightRule {
        let pattern: String
        let options: NSRegularExpression.Options
        let captureGroup: Int
        let color: Color
    }

    private func apply(
        rule: HighlightRule,
        source: String,
        attributed: inout AttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { return }
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: range)

        for match in matches {
            let groupRange = match.range(at: rule.captureGroup)
            guard
                groupRange.location != NSNotFound,
                let sourceRange = Range(groupRange, in: source),
                let attrRange = Range(sourceRange, in: attributed)
            else {
                continue
            }
            attributed[attrRange].foregroundColor = rule.color
        }
    }

    private func highlightRules(for language: String?) -> [HighlightRule] {
        var rules: [HighlightRule] = []

        let keywordColor = Color.purple
        let stringColor = Color.teal
        let numberColor = Color.orange
        let commentColor = Color.secondary
        let commandColor = Color.blue

        let stringRule = HighlightRule(
            pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,
            options: [],
            captureGroup: 0,
            color: stringColor
        )
        let numberRule = HighlightRule(
            pattern: #"\b\d+(?:\.\d+)?\b"#,
            options: [],
            captureGroup: 0,
            color: numberColor
        )
        let hashCommentRule = HighlightRule(
            pattern: #"(?m)#.*$"#,
            options: [],
            captureGroup: 0,
            color: commentColor
        )
        let slashCommentRule = HighlightRule(
            pattern: #"//.*|/\*[\s\S]*?\*/"#,
            options: [],
            captureGroup: 0,
            color: commentColor
        )
        let sqlCommentRule = HighlightRule(
            pattern: #"(?m)--.*$"#,
            options: [],
            captureGroup: 0,
            color: commentColor
        )

        if let shellRule = shellCommandRule(color: commandColor), isShellLanguage(language) {
            rules.append(shellRule)
        }

        if let keywordRule = keywordRule(for: language, color: keywordColor) {
            rules.append(keywordRule)
        }

        // 通用规则
        rules.append(stringRule)
        rules.append(numberRule)

        // 注释规则最后执行，覆盖其它颜色。
        if isSQLLanguage(language) {
            rules.append(sqlCommentRule)
        } else if isHashCommentLanguage(language) {
            rules.append(hashCommentRule)
        } else {
            rules.append(slashCommentRule)
            rules.append(hashCommentRule)
        }

        return rules
    }

    private func keywordRule(for language: String?, color: Color) -> HighlightRule? {
        let keywords: [String]
        switch language {
        case "swift":
            keywords = [
                "import", "class", "struct", "enum", "protocol", "extension", "func", "let", "var",
                "if", "else", "switch", "case", "default", "for", "while", "repeat", "guard",
                "return", "throw", "throws", "try", "catch", "async", "await", "actor",
                "in", "where", "defer", "do", "public", "private", "internal", "open", "final",
            ]
        case "bash", "sh", "zsh", "shell":
            keywords = [
                "if", "then", "else", "fi", "for", "in", "do", "done", "case", "esac",
                "while", "until", "function", "export", "local", "readonly", "source",
            ]
        case "python", "py":
            keywords = [
                "def", "class", "if", "elif", "else", "for", "while", "in", "return", "import",
                "from", "as", "try", "except", "finally", "with", "lambda", "yield", "async", "await",
            ]
        case "javascript", "js", "typescript", "ts":
            keywords = [
                "function", "const", "let", "var", "if", "else", "switch", "case", "default", "for",
                "while", "return", "class", "extends", "new", "import", "export", "from", "async", "await",
            ]
        case "json":
            // JSON 只高亮 key，避免对 true/false/null 做复杂分支。
            return HighlightRule(
                pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#,
                options: [],
                captureGroup: 0,
                color: color
            )
        case "yaml", "yml":
            return HighlightRule(
                pattern: #"(?m)^\s*([A-Za-z0-9_.-]+):"#,
                options: [],
                captureGroup: 1,
                color: color
            )
        case "sql":
            keywords = [
                "select", "from", "where", "join", "left", "right", "inner", "outer", "group", "by",
                "order", "insert", "into", "values", "update", "set", "delete", "create", "table",
                "alter", "drop", "limit", "offset",
            ]
        default:
            keywords = []
        }

        guard !keywords.isEmpty else { return nil }
        let escaped = keywords.map(NSRegularExpression.escapedPattern(for:))
        let pattern = #"\b("# + escaped.joined(separator: "|") + #")\b"#
        let options: NSRegularExpression.Options = (language == "sql") ? [.caseInsensitive] : []

        return HighlightRule(
            pattern: pattern,
            options: options,
            captureGroup: 0,
            color: color
        )
    }

    private func shellCommandRule(color: Color) -> HighlightRule? {
        HighlightRule(
            pattern: #"(?m)^\s*(?:\$\s*)?([A-Za-z_][A-Za-z0-9_./-]*)"#,
            options: [],
            captureGroup: 1,
            color: color
        )
    }

    // MARK: - Language Normalization

    private func normalizedLanguage(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // fenceInfo 可能带参数，如 "bash title=run.sh"
        guard let first = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        return first.lowercased()
    }

    private func isShellLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        return ["bash", "sh", "zsh", "shell", "console"].contains(language)
    }

    private func isSQLLanguage(_ language: String?) -> Bool {
        language == "sql"
    }

    private func isHashCommentLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        return ["bash", "sh", "zsh", "shell", "python", "py", "yaml", "yml", "ruby", "rb"].contains(language)
    }
}
