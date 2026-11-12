import Foundation

/// AGT-26 S6：线程页统一用这个消息模型。Codex（来自 Mirror）和 Claude（来自 /v1/harness/thread）都先转换成它，
/// 再交给同一套视图渲染。这里只有对话文本，工具调用折叠成一行摘要（做法参考 Happy 的 TurnFold）。
struct Transcript: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case user(String)
            case assistant(String)
            /// 一个 turn 里中间过程的折叠行（参考 ChatGPT「Thought for Ns」、Happy「Worked for 2m3s」）：
            /// steps 是被折叠的中间消息，点开逐条显示；seconds 是这轮从提问到回答的耗时，算不出来时为 nil
            case folded(steps: [String], seconds: Int?)
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
            var steps: [String] = []
            var askedAt: Date?
            for (i, item) in items.enumerated() {
                let text = (item["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let at = item["at"]?.stringValue.flatMap(TranscriptBuilder.parseDate)
                let id = "t\(t)-\(i)"
                switch item["role"]?.stringValue {
                case "user":
                    rows.append(.init(id: id, kind: .user(text), at: at)); askedAt = at
                case "assistant" where i == lastAssistant:
                    if !steps.isEmpty {
                        rows.append(.init(id: id + "-f", kind: .folded(steps: steps, seconds: elapsed(askedAt, at)), at: nil))
                    }
                    steps = []
                    rows.append(.init(id: id, kind: .assistant(text), at: at))
                case "assistant":
                    steps.append(text)
                default: continue
                }
            }
            if !steps.isEmpty { rows.append(.init(id: "t\(t)-f", kind: .folded(steps: steps, seconds: nil), at: nil)) }
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
                // Mirror 的消息没有时间，算不出耗时
                rows.append(.init(id: answer.id + "-f", kind: .folded(steps: pending.dropLast().map(\.text), seconds: nil), at: nil))
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
    /// 把本机会话文件读到的最近几行（live）叠到 Mirror 历史（base）上。
    /// Mirror 的消息没有时间，只能按内容对齐：在 base 里找 live 第一条用户消息最后一次出现的位置，
    /// 从那里截断再接上 live；对不上（live 比 Mirror 已有的还早）就保留 base 原样，只追加 base 里没有的 live 行。
    static func merge(_ base: Transcript, live: [Transcript.Row]) -> Transcript {
        guard !live.isEmpty else { return base }
        var out = base
        if let first = live.firstIndex(where: { if case .user = $0.kind { return true }; return false }),
           let cut = base.rows.lastIndex(where: { $0.kind == live[first].kind }) {
            out.rows = Array(base.rows[..<cut]) + live[first...]
            return out
        }
        let known = Set(base.rows.suffix(20).map { "\($0.kind)" })
        out.rows += live.filter { !known.contains("\($0.kind)") }
        return out
    }
}

extension TranscriptBuilder {
    static func elapsed(_ from: Date?, _ to: Date?) -> Int? {
        guard let from, let to, to >= from else { return nil }
        return Int(to.timeIntervalSince(from).rounded())
    }

    /// 「工作了 45 秒」「工作了 2 分 3 秒」「工作了 1 小时 5 分」；没有耗时就说步数
    static func foldLabel(steps: Int, seconds: Int?) -> String {
        guard let s = seconds else { return "中间过程 \(steps) 步" }
        if s < 60 { return "工作了 \(s) 秒" }
        if s < 3600 { return "工作了 \(s / 60) 分" + (s % 60 > 0 ? " \(s % 60) 秒" : "") }
        return "工作了 \(s / 3600) 小时" + ((s % 3600) / 60 > 0 ? " \((s % 3600) / 60) 分" : "")
    }

    /// 同时接受带小数秒和不带小数秒的 ISO 8601 时间（Date.ISO8601FormatStyle 是值类型，并发安全）
    static func parseDate(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: .iso8601))
    }
}
