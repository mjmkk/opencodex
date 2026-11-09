import Foundation

/// AGT-26 S6：线程页统一用这个消息模型。Codex（来自 Mirror）和 Claude（来自 /v1/harness/thread）都先转换成它，
/// 再交给同一套视图渲染。这里只有对话文本，工具调用折叠成一行摘要（做法参考 Happy 的 TurnFold）。
struct Transcript: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case user(String)
            case assistant(String)
            /// 一个 turn 里中间过程的折叠行：只有已结束的 turn 才折叠，运行中的 turn 保持展开
            case folded(count: Int, kinds: [String])
        }
        let id: String
        let kind: Kind
        let at: Date?
    }
    var rows: [Row]
    var model: String?
    var isPartial: Bool
    var hasMore: Bool
}

enum TranscriptBuilder {
    /// Claude：按 turn 处理。最后一条 assistant 是这轮的回答，前面的 assistant 都算中间过程，折叠起来
    static func claude(_ payload: JSONValue) throws -> Transcript {
        guard let root = payload.objectValue, root["ok"] == .bool(true),
              let thread = root["thread"]?.objectValue,
              let turns = thread["turns"]?.arrayValue else { throw CodexError.invalidState }
        var rows: [Transcript.Row] = []
        for (t, turnValue) in turns.enumerated() {
            let items = (turnValue.objectValue?["items"]?.arrayValue ?? []).compactMap { $0.objectValue }
            let lastAssistant = items.lastIndex { $0["role"]?.stringValue == "assistant" }
            var folded = 0
            for (i, item) in items.enumerated() {
                let text = (item["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let at = item["at"]?.stringValue.flatMap(TranscriptBuilder.parseDate)
                let id = "t\(t)-\(i)"
                switch item["role"]?.stringValue {
                case "user":
                    rows.append(.init(id: id, kind: .user(text), at: at))
                case "assistant" where i == lastAssistant:
                    if folded > 0 { rows.append(.init(id: id + "-f", kind: .folded(count: folded, kinds: ["过程"]), at: nil)) }
                    folded = 0
                    rows.append(.init(id: id, kind: .assistant(text), at: at))
                case "assistant":
                    folded += 1
                default: continue
                }
            }
            if folded > 0 { rows.append(.init(id: "t\(t)-f", kind: .folded(count: folded, kinds: ["过程"]), at: nil)) }
        }
        return Transcript(rows: rows, model: thread["model"]?.stringValue, isPartial: false, hasMore: false)
    }

    /// Codex：Mirror 里大多数消息没有 phase，长线程一轮能有上百条 assistant。和 Claude 一样按轮处理：
    /// 两条用户消息之间，最后一条 assistant 是回答，前面的都折叠成“中间过程”
    static func codex(_ history: ThreadHistory) -> Transcript {
        var rows: [Transcript.Row] = []
        var pending: [ThreadHistory.Message] = []
        func flush() {
            guard let answer = pending.last else { return }
            if pending.count > 1 {
                rows.append(.init(id: answer.id + "-f", kind: .folded(count: pending.count - 1, kinds: ["过程"]), at: nil))
            }
            rows.append(.init(id: answer.id, kind: .assistant(answer.text), at: answer.sentAt))
            pending = []
        }
        for var m in history.messages {
            // 原生消息常带结尾换行，不去掉的话气泡底部会空出一截
            m.text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !m.text.isEmpty else { continue }
            switch m.role {
            case "user": flush(); rows.append(.init(id: m.id, kind: .user(m.text), at: m.sentAt))
            case "assistant": pending.append(m)
            default: continue
            }
        }
        flush()
        return Transcript(rows: rows, model: nil, isPartial: history.isPartial, hasMore: history.hasMore)
    }
}

extension TranscriptBuilder {
    /// 同时接受带小数秒和不带小数秒的 ISO 8601 时间（Date.ISO8601FormatStyle 是值类型，并发安全）
    static func parseDate(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: .iso8601))
    }
}
