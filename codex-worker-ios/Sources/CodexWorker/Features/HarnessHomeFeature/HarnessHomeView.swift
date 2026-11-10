import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// AGT-26 S6：左侧抽屉里的 Goal 树。排版学 ChatGPT 抽屉和 Happy 会话列表：
/// - 平铺列表、小号灰色分区标题（需要你 / 进行中 / 其他），没有卡片和分隔线
/// - Goal 行：标题 + 第二行「Issue · Master 跑在哪」；点一下展开成员，默认收起；收起时需要你处理的成员单独露出来
/// - 成员行：30pt harness 图标（右下角状态点）+ 标题 + 「角色 · harness · 机器 · 模型」；子代理折叠在主线程下面
/// - 当前打开的线程用浅灰底高亮（ChatGPT 选中行）
/// - 只显示对话入口，不显示工具调用，也没有派 CALL 按钮；长按可复制原生 id、跳 Linear
struct HarnessHomeView: View {
    let goals: [HarnessGoal]
    var currentId: String? = nil
    let isRefreshing: Bool
    let failure: String?
    let refresh: () async -> Void
    let openThread: (HarnessMember) -> Void

    // 启动参数 -AGTExpand <Issue>：启动后先展开指定的 Goal（模拟器自动化验证用）
    @State private var expanded: Set<String> = UserDefaults.standard.string(forKey: "AGTExpand").map { [$0] } ?? []
    @State private var expandedSubagents: Set<String> = []
    @State private var expandedThinkers: Set<String> = []
    @State private var copiedId: String?
    @State private var renaming: RenameTarget?

    struct RenameTarget: Identifiable {
        var id: String { threadId ?? issueId ?? "" }
        let threadId: String?
        let issueId: String?
        let currentName: String
        let subtitle: String
        let revision: Int
    }

    private var needYou: [HarnessGoal] { goals.filter(\.needsYou) }
    private var running: [HarnessGoal] { goals.filter { !$0.needsYou && $0.runningCount > 0 } }
    private var rest: [HarnessGoal] { goals.filter { !$0.needsYou && $0.runningCount == 0 } }

    var body: some View {
        List {
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            section("需要你", needYou)
            section("进行中", running)
            section("其他", rest)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .navigationTitle("工作")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await refresh() }
        .overlay {
            if goals.isEmpty && !isRefreshing && failure == nil {
                ContentUnavailableView("还没有进行中的 Goal", systemImage: "circle.dashed",
                    description: Text("在 Linear Issue 上打 Goal 标签后会出现在这里。"))
            }
        }
        .overlay(alignment: .bottom) {
            if copiedId != nil {
                Text("已复制原生 id").font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .sheet(item: $renaming) { t in
            RenameSheet(title: t.currentName, subtitle: t.subtitle) { name in
                guard let r = try? await APIClient.live.harnessRename(t.threadId, t.issueId, name, t.revision),
                      r.objectValue?["ok"] == .bool(true) else { return false }
                await refresh(); return true
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [HarnessGoal]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { goalRows($0) }
            } header: {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(nil)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Goal

    @ViewBuilder
    private func goalRows(_ goal: HarnessGoal) -> some View {
        let isOpen = expanded.contains(goal.id)
        Button { toggle(&expanded, goal.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // 标题是主角，最多两行；有 Master 时旁边加蓝色小人图标，一眼看出这个 Goal 正被 Master 推进
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(goal.title).font(.body.weight(.semibold)).lineLimit(2)
                        if goal.master != nil {
                            Image(systemName: "person.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.running)
                        }
                    }
                    HStack(spacing: 4) {
                        if goal.title != goal.id { Text(goal.id).monospacedDigit() }
                        if let m = goal.master {
                            Text("Master · " + (m.hostLabel ?? m.harnessName))
                        } else {
                            Text("\(goal.members.count) 个线程")
                        }
                    }
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if goal.runningCount > 0 && !goal.needsYou {
                    Text("\(goal.runningCount) 个在跑").font(.footnote).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renaming = .init(threadId: goal.master?.id, issueId: goal.id,
                                     currentName: goal.title, subtitle: goal.id, revision: 0) }
                label: { Label("改名", systemImage: "pencil") }
            linearLink(goal)
        }
        .accessibilityHint(isOpen ? "收起成员" : "展开成员")

        if isOpen {
            // Master 排第一；其余按 需要你 → 运行中 → 其他 排，同一档保持原顺序。思考线程超过 3 条时折叠
            let rank: (HarnessMember) -> Int = { m in
                m.role == .master ? 0 : m.status == .needsYou ? 1 : m.status == .running ? 2 : 3
            }
            let others = goal.members.filter { $0.role != .thinker }.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            let thinkers = goal.members.filter { $0.role == .thinker }
            ForEach(others) { m in memberRows(m, goal: goal) }
            if thinkers.count > 3 && !expandedThinkers.contains(goal.id) {
                Button { toggle(&expandedThinkers, goal.id) } label: {
                    Text("还有 \(thinkers.count) 个思考线程")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.leading, 48).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(thinkers) { m in memberRows(m, goal: goal) }
            }
        } else {
            // 收起时，需要你处理的成员单独露出来，点一下直接进
            ForEach(goal.surfaced) { m in memberRow(m, goal: goal, indent: 8) }
        }
    }

    // MARK: - 成员

    @ViewBuilder
    private func memberRows(_ m: HarnessMember, goal: HarnessGoal) -> some View {
        memberRow(m, goal: goal, indent: 8)
        if !m.subagents.isEmpty {
            let open = expandedSubagents.contains(m.id)
            Button { toggle(&expandedSubagents, m.id) } label: {
                HStack(spacing: 4) {
                    Text(open ? "收起子代理" : "\(m.subagents.count) 个子代理")
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.leading, 56).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(m.subagents) { s in memberRow(s, goal: goal, indent: 48) }
            }
        }
    }

    private func memberRow(_ m: HarnessMember, goal: HarnessGoal, indent: CGFloat) -> some View {
        let selected = m.id == currentId
        // Goal 行已经用了 Master 的标题，Master 行就只写角色，不重复一遍
        // 成员行只说“这条线程是什么”：Master 就写 Master；其他线程去掉和 Goal 重复的「BOX-166 · 」「AGT-26「…」·」前缀
        let title: String = m.role == .master ? "Master" : Self.shortTitle(m.title, goal: goal) ?? m.roleLabel
        let detail: String = m.roleLabel + " · " + m.runtimeLine
        let needs = m.status == .needsYou
        let a11y: String = [title, detail, needs ? "需要你处理" : nil].compactMap { $0 }.joined(separator: "，")
        let highlight: Color = selected ? Color.secondary.opacity(0.12) : Color.clear
        return Button { openThread(m) } label: {
            HStack(spacing: 10) {
                StatusIcon(member: m)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if needs {
                    Text("需要你").font(.caption.weight(.semibold)).foregroundStyle(Theme.needsYou)
                }
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 6)
            .background(highlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renaming = .init(threadId: m.id, issueId: nil,
                                     currentName: title, subtitle: m.roleLabel + " · " + m.id, revision: 0) }
                label: { Label("改名", systemImage: "pencil") }
            Button { copy(m.id) } label: { Label("复制原生 id", systemImage: "doc.on.doc") }
            linearLink(goal)
        }
        .accessibilityLabel(a11y)
    }

    // MARK: - 小部件

    @ViewBuilder
    private func linearLink(_ goal: HarnessGoal) -> some View {
        if let url = goal.issueURL {
            Link(destination: url) { Label("在 Linear 打开 " + goal.id, systemImage: "arrow.up.right.square") }
        }
    }

    static func shortTitle(_ raw: String?, goal: HarnessGoal) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t == goal.id { return nil }  // 标题只有 Issue 号，等于没有标题
        for sep in [" · ", "｜", " | ", "：", ": ", " "] {
            if t.hasPrefix(goal.id + sep) { t.removeFirst(goal.id.count + sep.count); break }
        }
        if t.hasPrefix(goal.id) && t.count > goal.id.count {
            // 例如「AGT-26「AGT 协作开发」· Worker」：去掉 Issue 号和书名号里的项目名
            var rest = t.dropFirst(goal.id.count)
            if rest.first == "「", let end = rest.firstIndex(of: "」") { rest = rest[rest.index(after: end)...] }
            t = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ·｜|：:"))
        }
        return t.isEmpty ? nil : t
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        Haptics.light()
        withAnimation(.snappy(duration: 0.2)) {
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
        }
    }

    private func copy(_ id: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = id
#endif
        withAnimation { copiedId = id }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { copiedId = nil } }
    }
}
