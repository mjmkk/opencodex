import Foundation

/// A text presentation only: matching syntax does not establish system provenance or approval.
/// The original message remains available verbatim and is never replaced in storage.
struct QuestionReplyPresentation: Equatable {
    struct Item: Equatable {
        let question: String
        let answer: String
    }

    let items: [Item]
    let originalText: String

    init?(_ text: String, isCurrentUser: Bool) {
        let opening = "<send_user_message_question_reply>"
        let closing = "</send_user_message_question_reply>"
        // Do not reinterpret indented, quoted, fenced or mixed literal examples.
        guard isCurrentUser, text.hasPrefix(opening) else { return nil }
        let envelope = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard envelope.hasSuffix(closing), envelope.utf8.count <= 131_072 else { return nil }
        let payload = envelope.dropFirst(opening.count).dropLast(closing.count)
        var reader = ReplyTextReader(bytes: Array(payload.utf8))
        guard let parsed = reader.readItems() else { return nil }
        items = parsed
        originalText = text
    }
}

/// The narrow grammar keeps duplicate/unknown keys and non-string values in the raw fallback.
/// Foundation decodes JSON string escapes; this reader only recognizes the surrounding structure.
private struct ReplyTextReader {
    let bytes: [UInt8]
    private var index = 0
    private let fields: Set<String> = ["questionItemId", "question", "answer"]

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readItems() -> [QuestionReplyPresentation.Item]? {
        guard take(91) else { return nil } // [
        var items: [QuestionReplyPresentation.Item] = []
        repeat {
            guard items.count < 16, take(123) else { return nil } // {
            var values: [String: String] = [:]
            repeat {
                guard let key = string(), fields.contains(key), values[key] == nil,
                      take(58), let value = string() else { return nil } // :
                values[key] = value
            } while take(44) // ,
            guard take(125), Set(values.keys) == fields,
                  let question = values["question"], !question.isEmpty,
                  let answer = values["answer"], !answer.isEmpty,
                  let identifier = values["questionItemId"], !identifier.isEmpty else { return nil }
            items.append(.init(question: question, answer: answer))
        } while take(44)
        guard take(93) else { return nil } // ]
        skipWhitespace()
        return index == bytes.count ? items : nil
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func string() -> String? {
        skipWhitespace()
        let start = index
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case 92: index += 2 // Skip an escaped byte; JSONDecoder validates its full sequence.
            case 34:
                index += 1
                return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            default: index += 1
            }
        }
        return nil
    }
}
