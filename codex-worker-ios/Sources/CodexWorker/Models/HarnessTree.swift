import Foundation

/// AGT-26 S6：首页以 Goal 为主轴。一个 Goal 下有思考线程、Master 和 Worker，子代理挂在各自主线程下面。
/// 数据来自 `GET /v1/harness/tree`：Linear 当前 Goal 父链 + Registry 正式成员的只读投影，客户端不推断角色。
struct HarnessGoal: Identifiable, Equatable, Sendable {
    let id: String              // Linear Issue，例如 BOX-166
    let issueURL: URL?
    let members: [HarnessMember]
    /// Linear Issue 的标题（服务端从 Linear 取，可能没有）
    var issueTitle: String? = nil
    var ownershipStatus: String? = nil
    var workCount: Int = 0

    var needsRelationshipReview: Bool { ownershipStatus == "unassigned" || ownershipStatus == "unavailable" }
    var executionCount: Int { members.filter { $0.role != .thinker }.count }
    var thinkers: [HarnessMember] { members.filter { $0.role == .thinker } }
    var workers: [HarnessMember] {
        members.enumerated().filter { $0.element.role == .worker }
            .sorted { (Self.rank($0.element), $0.offset) < (Self.rank($1.element), $1.offset) }.map(\.element)
    }
    private static func rank(_ member: HarnessMember) -> Int {
        member.status == .needsYou ? 0 : member.status == .running ? 1 : 2
    }

    /// 大 Goal 只露出需要处理、当前查看及最多三个运行中的工作线程；小 Goal 保持直达。
    func overviewMembers(currentID: String?) -> [HarnessMember] {
        let candidates = workers
        let running = Set(candidates.filter { $0.status == .running }.prefix(3).map(\.identityKey))
        return candidates.filter { member in
            candidates.count <= 3 || member.status == .needsYou || running.contains(member.identityKey)
                || member.id == currentID || member.subagents.contains { $0.id == currentID }
        }
    }

    func directoryMembers(_ kind: HarnessDirectoryKind, matching query: String = "") -> [HarnessMember] {
        let candidates = kind == .workers ? workers : thinkers
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return candidates }
        return candidates.filter { member in
            let fields = [member.title, member.id, member.harnessName, member.host, member.hostLabel, member.model]
                .compactMap { $0 } + member.workIssues.flatMap { [$0.id, $0.title].compactMap { $0 } }
            let text = fields.joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    var master: HarnessMember? { members.first { $0.role == .master } }
    /// Goal 标题优先使用 Master 线程名，再退回 Linear Goal 标题和 Issue 号；旧响应保留单线程名称兼容。
    var title: String {
        if let m = master, let n = Self.threadName(m.title, goalId: id) { return n }
        // 新版接口已经按真实 Goal 聚合，不能再拿某个 Worker 的标题冒充 Goal 名。
        if ownershipStatus != nil { return issueTitle ?? id }
        let threads = members.filter { $0.role != .thinker }
        if threads.count == 1, let n = Self.threadName(threads[0].title, goalId: id) { return n }
        return issueTitle ?? id
    }

    /// 从线程标题里取出“名字”：「AGT-26「AGT 协作开发」· Master」→「AGT 协作开发」，
    /// 「AGT-47 演练 · Codex Master」→「演练」，「BOX-166 · SDK CTest 核查」→「SDK CTest 核查」
    static func threadName(_ raw: String?, goalId: String) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != goalId else { return nil }
        if let a = t.firstIndex(of: "「"), let b = t[a...].firstIndex(of: "」"), t.index(after: a) < b {
            return String(t[t.index(after: a)..<b])
        }
        if t.hasPrefix(goalId) { t = String(t.dropFirst(goalId.count)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ·｜|：:"))
        // 去掉结尾的角色说明，例如「 · Codex Master」「 · Master（接续）」
        if let r = t.range(of: " · ", options: .backwards), t[r.upperBound...].contains("Master") {
            t = String(t[..<r.lowerBound])
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "Master" ? nil : t
    }
    /// 收起时露出来的成员：需要 Human 处理的（待审批、待决策）
    var surfaced: [HarnessMember] { members.filter { $0.status == .needsYou } }
    var needsYou: Bool { !surfaced.isEmpty }
    var runningCount: Int { members.filter { $0.status == .running }.count }
}

enum HarnessDirectoryKind: String, Hashable, Sendable {
    case workers, thinkers
    var title: String { self == .workers ? "工作线程" : "思考对话" }
    var icon: String { self == .workers ? "list.bullet" : "bubble.left.and.bubble.right" }
}

struct HarnessMember: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case thinker = "chatgpt", master, worker, subagent }
    enum Status: Equatable, Sendable { case unknown, idle, running, needsYou, done }

    let id: String              // 原生 id：Codex thread / Claude session / ChatGPT conversation
    let role: Role
    let kind: String            // codex / claude / chatgpt
    let host: String?
    let title: String?
    let model: String?
    var status: Status = .unknown
    var subagents: [HarnessMember] = []
    /// needs_you 时在等什么：Node 从钩子事件里取的工具名和一行摘要（命令或文件路径）
    var waiting: Waiting?
    struct WorkIssue: Equatable, Sendable, Identifiable {
        var id: String
        var title: String?
        var role: String?
        var url: URL? { URL(string: "https://linear.app/mjmk/issue/" + id) }
    }
    var workIssues: [WorkIssue] = []
    var identityKey: String { [kind, host ?? "", id].joined(separator: "|") }
    var externalConversationURL: URL? {
        guard kind == "chatgpt", UUID(uuidString: id) != nil else { return nil }
        return URL(string: "https://chatgpt.com/c/" + id)
    }

    struct Waiting: Equatable, Sendable {
        let isPermission: Bool
        let tool: String?
        let summary: String
    }

    var roleLabel: String {
        switch role {
        case .thinker: return "思考"
        case .master: return "Master"
        case .worker: return workIssues.contains(where: { $0.role == "master" }) ? "工作负责人" : "Worker"
        case .subagent: return "子代理"
        }
    }

    /// 第二行：harness · 机器 · 模型。缺的部分不显示，不编造
    var runtimeLine: String {
        [harnessName, hostLabel, model].compactMap { $0 }.joined(separator: " · ")
    }

    var harnessName: String {
        switch kind {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "chatgpt": return "ChatGPT"
        default: return kind
        }
    }

    var hostLabel: String? { HarnessMember.hostLabel(host) }

    /// Registry 里的 host_id 是机器内部标识，这里换成人能认出来的名字
    static func hostLabel(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        switch host {
        case "local": return "spirit-master"
        case "mac-m1pro": return "M1 Mac"
        case "agt-ubuntu-worker", "remote-ssh-discovered:agt-ubuntu-worker": return "Ubuntu"
        default:
            return host.hasPrefix("remote-control:") ? "远程设备" : host
        }
    }
}

enum HarnessTreeDecoder {
    /// 解析 `/v1/harness/tree`。字段不合法的成员直接丢弃，不让整页失败
    static func goals(_ payload: JSONValue) throws -> [HarnessGoal] {
        guard let root = payload.objectValue, root["ok"] == .bool(true),
              let goals = root["goals"]?.arrayValue else { throw CodexError.invalidState }
        return goals.compactMap { value -> HarnessGoal? in
            guard let g = value.objectValue, let issue = g["issue_id"]?.stringValue else { return nil }
            let members = (g["members"]?.arrayValue ?? []).compactMap { member($0) }
            guard members.contains(where: { $0.role == .master || $0.role == .worker }) else { return nil }
            return HarnessGoal(id: issue, issueURL: URL(string: "https://linear.app/mjmk/issue/" + issue),
                               members: members, issueTitle: g["title"]?.stringValue,
                               ownershipStatus: g["ownership_status"]?.stringValue,
                               workCount: g["works"]?.arrayValue?.filter { $0.objectValue?["issue_id"]?.stringValue != issue }.count ?? 0)
        }
    }

    private static func member(_ value: JSONValue, role forced: HarnessMember.Role? = nil) -> HarnessMember? {
        guard let m = value.objectValue, let id = m["id"]?.stringValue, !id.isEmpty,
              let role = forced ?? m["role"]?.stringValue.flatMap(HarnessMember.Role.init(rawValue:)),
              let kind = m["kind"]?.stringValue else { return nil }
        var member = HarnessMember(id: id, role: role, kind: kind, host: m["host_id"]?.stringValue,
                                   title: m["title"]?.stringValue, model: m["model"]?.stringValue)
        member.status = status(m["status"]?.stringValue)
        member.workIssues = (m["work_issues"]?.arrayValue ?? []).compactMap { value in
            guard let w = value.objectValue, let id = w["issue_id"]?.stringValue else { return nil }
            return .init(id: id, title: w["title"]?.stringValue, role: w["role"]?.stringValue)
        }
        member.subagents = (m["subagents"]?.arrayValue ?? []).compactMap { Self.member($0, role: .subagent) }
        if member.status == .needsYou, let w = m["waiting"]?.objectValue {
            member.waiting = .init(isPermission: w["kind"]?.stringValue == "permission",
                                   tool: w["tool"]?.stringValue, summary: w["summary"]?.stringValue ?? "")
        }
        return member
    }

    /// Node 用钩子事件汇总出来的状态；没有观测到就是 unknown，不推测
    static func status(_ raw: String?) -> HarnessMember.Status {
        switch raw {
        case "needs_you": return .needsYou
        case "running": return .running
        case "idle": return .idle
        case "done": return .done
        default: return .unknown
        }
    }
}
