//
//  MessageLinkNormalizer.swift
//  CodexWorker
//
//  消息链接标准化：把路径引用与裸 URL 转成可点击 Markdown 链接
//

import Foundation

public struct MessageLinkNormalizer: Sendable {
    public static let live = MessageLinkNormalizer()

    public init() {}

    public func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var output = collapseNestedMarkdownLinks(raw)
        output = unwrapBacktickedMarkdownLinks(output)
        output = normalizeExistingCodexFileMarkdownLinks(output)
        output = replaceMatches(
            in: output,
            pattern: #"`(?:/|\.\./|\./|[A-Za-z0-9._-]+/)[A-Za-z0-9._~\-/]*\.[A-Za-z0-9._-]+(?::\d+(?::\d+)?)?(?:#L\d+(?:C\d+)?)?`"#,
            protectedRanges: collectProtectedRanges(in: output),
            transform: { candidate in
                guard let stripped = stripBackticks(candidate) else { return nil }
                let (core, trailing) = splitTrailingPunctuation(stripped)
                guard !core.isEmpty else { return nil }
                guard let destination = makeCodexFileURLString(ref: core) else {
                    return nil
                }
                return "[\(core)](\(destination))\(trailing)"
            }
        )

        output = replaceMatches(
            in: output,
            pattern: #"`https?://[^\s<>()`]+`"#,
            protectedRanges: collectProtectedRanges(in: output),
            transform: { candidate in
                guard let stripped = stripBackticks(candidate) else { return nil }
                let (core, trailing) = splitTrailingPunctuation(stripped)
                guard !core.isEmpty else { return nil }
                return "[\(core)](\(core))\(trailing)"
            }
        )

        output = replaceMatches(
            in: output,
            pattern: #"(?:(?<=\s)|(?<=^)|(?<=[\("']))((?:/|\.\./|\./|[A-Za-z0-9._-]+/)[A-Za-z0-9._~\-/]*\.[A-Za-z0-9._-]+(?::\d+(?::\d+)?)?(?:#L\d+(?:C\d+)?)?)"#,
            protectedRanges: collectProtectedRanges(in: output),
            transform: { candidate in
                guard !candidate.contains("http://"), !candidate.contains("https://") else {
                    return nil
                }
                let (core, trailing) = splitTrailingPunctuation(candidate)
                guard !core.isEmpty else { return nil }
                guard let destination = makeCodexFileURLString(ref: core) else {
                    return nil
                }
                return "[\(core)](\(destination))\(trailing)"
            }
        )

        output = replaceMatches(
            in: output,
            pattern: #"https?://[^\s<>()`]+"#,
            protectedRanges: collectProtectedRanges(in: output),
            transform: { candidate in
                if isAlreadyMarkdownLink(url: candidate, in: output) {
                    return nil
                }
                let (core, trailing) = splitTrailingPunctuation(candidate)
                guard !core.isEmpty else { return nil }
                return "[\(core)](\(core))\(trailing)"
            }
        )

        return output
    }

    private func unwrapBacktickedMarkdownLinks(_ text: String) -> String {
        let pattern = #"`(\[[^\]\n]+\]\((?:codexfs://open\?ref=[^)\n]+|https?://[^)\n]+)\))`"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        var output = text
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            let innerRange = match.range(at: 1)
            guard
                fullRange.location != NSNotFound,
                let swiftFullRange = Range(fullRange, in: output),
                let swiftInnerRange = Range(innerRange, in: output)
            else {
                continue
            }
            let inner = String(output[swiftInnerRange])
            output.replaceSubrange(swiftFullRange, with: inner)
        }
        return output
    }

    private func normalizeExistingCodexFileMarkdownLinks(_ text: String) -> String {
        let pattern = #"\[([^\]\n]+)\]\((codexfs://open\?ref=[^)\n]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        var output = text
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            let labelRange = match.range(at: 1)
            let destinationRange = match.range(at: 2)
            guard
                fullRange.location != NSNotFound,
                let swiftFullRange = Range(fullRange, in: output),
                let swiftLabelRange = Range(labelRange, in: output),
                let swiftDestinationRange = Range(destinationRange, in: output)
            else {
                continue
            }

            let rawLabel = String(output[swiftLabelRange])
            let label = unwrapInlineCodeLabel(rawLabel)
            let destination = String(output[swiftDestinationRange])
            guard let ref = extractCodexFileRef(from: destination),
                  let normalizedDestination = makeCodexFileURLString(ref: ref)
            else {
                continue
            }
            output.replaceSubrange(swiftFullRange, with: "[\(label)](\(normalizedDestination))")
        }
        return output
    }

    private func collapseNestedMarkdownLinks(_ text: String) -> String {
        // 历史消息可能被旧版本改写为 [[label](innerURL)](outerURL)，这里统一压平成 [label](innerURL)。
        let pattern = #"\[\[([^\]\n]+)\]\(([^)\n]+)\)\]\(([^)\n]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        var output = text
        while true {
            let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
            guard !matches.isEmpty else { break }
            for match in matches.reversed() {
                let fullRange = match.range(at: 0)
                let labelRange = match.range(at: 1)
                let innerURLRange = match.range(at: 2)
                guard
                    fullRange.location != NSNotFound,
                    let swiftFullRange = Range(fullRange, in: output),
                    let swiftLabelRange = Range(labelRange, in: output),
                    let swiftInnerURLRange = Range(innerURLRange, in: output)
                else {
                    continue
                }
                let label = output[swiftLabelRange]
                let innerURL = output[swiftInnerURLRange]
                output.replaceSubrange(swiftFullRange, with: "[\(label)](\(innerURL))")
            }
        }
        return output
    }

    private func makeCodexFileURLString(ref: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return "codexfs://open?ref=\(encodedRef)"
    }

    private func extractCodexFileRef(from destination: String) -> String? {
        if let components = URLComponents(string: destination),
           let value = components.queryItems?.first(where: { $0.name == "ref" })?.value {
            return value.removingPercentEncoding ?? value
        }

        guard let refRange = destination.range(of: "ref=", options: [.caseInsensitive]) else {
            return nil
        }
        let raw = String(destination[refRange.upperBound...])
        return raw.removingPercentEncoding ?? raw
    }

    private func unwrapInlineCodeLabel(_ label: String) -> String {
        guard label.count >= 2, label.hasPrefix("`"), label.hasSuffix("`") else {
            return label
        }
        return String(label.dropFirst().dropLast())
    }

    private func stripBackticks(_ candidate: String) -> String? {
        guard candidate.count >= 2, candidate.hasPrefix("`"), candidate.hasSuffix("`") else {
            return nil
        }
        return String(candidate.dropFirst().dropLast())
    }

    private func collectProtectedRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []

        let blockPattern = #"```[\s\S]*?```"#
        if let regex = try? NSRegularExpression(pattern: blockPattern) {
            let all = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            ranges.append(contentsOf: all.map(\.range))
        }

        // 已存在的 Markdown 链接不再重复改写，避免出现 [[...](...)](...)。
        let markdownLinkPattern = #"!?\[[^\]\n]+\]\([^\)\n]+\)"#
        if let regex = try? NSRegularExpression(pattern: markdownLinkPattern) {
            let all = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            ranges.append(contentsOf: all.map(\.range))
        }

        return mergeOverlappingRanges(ranges)
    }

    private func mergeOverlappingRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }

        var merged: [NSRange] = [sorted[0]]
        for current in sorted.dropFirst() {
            guard let last = merged.last else {
                merged.append(current)
                continue
            }
            let lastEnd = last.location + last.length
            let currentEnd = current.location + current.length
            if current.location <= lastEnd {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(lastEnd, currentEnd) - last.location
                )
            } else {
                merged.append(current)
            }
        }
        return merged
    }

    private func replaceMatches(
        in text: String,
        pattern: String,
        protectedRanges: [NSRange],
        transform: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let range: NSRange
            if match.numberOfRanges > 1 {
                range = match.range(at: 1)
            } else {
                range = match.range(at: 0)
            }
            guard range.location != NSNotFound else { continue }
            if protectedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                continue
            }
            guard let swiftRange = Range(range, in: result) else { continue }
            let candidate = String(result[swiftRange])
            guard let replacement = transform(candidate) else { continue }
            result.replaceSubrange(swiftRange, with: replacement)
        }

        return result
    }

    private func splitTrailingPunctuation(_ raw: String) -> (String, String) {
        let trailingSet = CharacterSet(charactersIn: ".,;:!?)]}`，。；：！？）】》」』”’")
        var core = raw
        var trailing = ""

        while let scalar = core.unicodeScalars.last, trailingSet.contains(scalar) {
            trailing.insert(Character(scalar), at: trailing.startIndex)
            core.removeLast()
        }

        return (core, trailing)
    }

    private func isAlreadyMarkdownLink(url: String, in text: String) -> Bool {
        text.contains("](\(url))")
    }
}
