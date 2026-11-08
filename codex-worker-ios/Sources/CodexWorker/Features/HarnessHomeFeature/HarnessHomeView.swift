import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// AGT-26 S6：首页以 Goal 为主轴，按 AGT-12 原型 v3 实现。
/// - Goal 默认收起；收起时，需要 Human 处理的成员单独露出一行
/// - 展开后按 思考 → Master → Worker 排列；子代理默认折叠在各自主线程下面
/// - 每条线程都显示 harness · 机器 · 模型，可以复制原生 id，也可以跳到 Linear
/// - 只展示对话，不展示工具调用；派 CALL 由 Agent 完成，界面上没有派 CALL 按钮
struct HarnessHomeView: View {
    let goals: [HarnessGoal]
    let isRefreshing: Bool
    let failure: String?
    let refresh: () async -> Void
    let openThread: (HarnessMember) -> Void

    // 启动参数 -AGTExpand <Issue>：启动后先展开指定的 Goal（模拟器自动化验证用）
    @State private var expanded: Set<String> = UserDefaults.standard.string(forKey: "AGTExpand").map { [$0] } ?? []
    @State private var expandedSubagents: Set<String> = []
    @State private var expandedThinkers: Set<String> = []
    @State private var copiedId: String?

    private var needYou: [HarnessGoal] { goals.filter(\.needsYou) }
    private var others: [HarnessGoal] { goals.filter { !$0.needsYou } }

    var body: some View {
        List {
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
            }
            if !needYou.isEmpty {
                Section { ForEach(needYou) { goalRows($0) } } header: { Text("需要你").foregroundStyle(.orange) }
            }
            Section("进行中") { ForEach(others) { goalRows($0) } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("工作")
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
    }

    // MARK: - Goal

    @ViewBuilder
    private func goalRows(_ goal: HarnessGoal) -> some View {
        let isOpen = expanded.contains(goal.id)
        Button { toggle(&expanded, goal.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(goal.title).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        statusText(goal.needsYou ? .needsYou : goal.runningCount > 0 ? .running : .unknown)
                    }
                    HStack(spacing: 6) {
                        linearTag(goal)
                        if let master = goal.master {
                            Text("Master · " + master.runtimeLine).lineLimit(1)
                        } else {
                            Text("没有 Master")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !isOpen {
                        ForEach(goal.surfaced) { m in
                            // 没有标题时显示「角色 · harness · 机器」，不显示原生 id（id 只在复制时用）
                            Label((m.title ?? (m.roleLabel + " · " + m.runtimeLine)) + " · 待你处理",
                                  systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "收起成员" : "展开成员")

        if isOpen {
            // 思考线程超过 3 条时折叠成一行，避免把 Master 和 Worker 挤到下面（AGT-26 有 24 条）
            let thinkers = goal.members.filter { $0.role == .thinker }
            // Master 排第一；Worker 按 需要你 → 运行中 → 其他 排序，同一档内保持原来的顺序
            let rank: (HarnessMember) -> Int = { m in
                m.role == .master ? 0 : m.status == .needsYou ? 1 : m.status == .running ? 2 : 3
            }
            let others = goal.members.filter { $0.role != .thinker }.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            let foldThinkers = thinkers.count > 3 && !expandedThinkers.contains(goal.id)
            ForEach(others) { m in memberRows(m, goal: goal) }
            if foldThinkers {
                Button { toggle(&expandedThinkers, goal.id) } label: {
                    HStack(spacing: 8) {
                        Text("思考").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            .frame(width: 46, alignment: .leading)
                        Text("\(thinkers.count) 个思考线程").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 18)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(thinkers) { m in memberRows(m, goal: goal) }
            }
        }
    }

    // MARK: - 成员

    @ViewBuilder
    private func memberRows(_ m: HarnessMember, goal: HarnessGoal) -> some View {
        let subsOpen = expandedSubagents.contains(m.id)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(m.roleLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(m.role == .thinker ? Color.accentColor : .secondary)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if !m.subagents.isEmpty {
                        Button { toggle(&expandedSubagents, m.id) } label: {
                            Image(systemName: "chevron.right").font(.caption2)
                                .rotationEffect(.degrees(subsOpen ? 90 : 0))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(subsOpen ? "收起子代理" : "展开子代理")
                    }
                    Text(m.title ?? (m.runtimeLine + " · " + shortId(m.id))).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 8)
                    statusText(m.status)
                }
                Text(m.runtimeLine + (m.subagents.isEmpty || subsOpen ? "" : " · \(m.subagents.count) 个子代理"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 18)
        .contentShape(Rectangle())
        .onTapGesture { openThread(m) }
        .contextMenu {
            Button { copy(m.id) } label: { Label("复制原生 id", systemImage: "doc.on.doc") }
            if let url = goal.issueURL {
                Link(destination: url) { Label("在 Linear 打开 " + goal.id, systemImage: "arrow.up.right.square") }
            }
        }
        .swipeActions(edge: .trailing) {
            Button { copy(m.id) } label: { Label("复制 id", systemImage: "doc.on.doc") }.tint(.blue)
        }

        if subsOpen {
            // 子代理只有一层，不会再往下嵌套，所以这里用单独的行视图，避免递归的 some View
            ForEach(m.subagents) { s in subagentRow(s, goal: goal) }
        }
    }

    private func subagentRow(_ s: HarnessMember, goal: HarnessGoal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("子代理").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(s.title ?? shortId(s.id)).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 8)
                    statusText(s.status)
                }
                Text(s.runtimeLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 34)
        .contentShape(Rectangle())
        .onTapGesture { openThread(s) }
        .contextMenu { Button { copy(s.id) } label: { Label("复制原生 id", systemImage: "doc.on.doc") } }
    }

    // MARK: - 小部件

    @ViewBuilder
    private func linearTag(_ goal: HarnessGoal) -> some View {
        if let url = goal.issueURL {
            Link(destination: url) {
                HStack(spacing: 2) {
                    Text(goal.id)
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("在 Linear 打开 " + goal.id)
        }
    }

    @ViewBuilder
    private func statusText(_ s: HarnessMember.Status) -> some View {
        switch s {
        case .needsYou: Text("需要你").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .running: Text("运行中").font(.caption).foregroundStyle(Color.accentColor)
        case .done: Text("已完成").font(.caption).foregroundStyle(.green)
        case .idle: Text("空闲").font(.caption).foregroundStyle(.secondary)
        case .unknown: EmptyView()
        }
    }

    private func shortId(_ id: String) -> String { String(id.prefix(8)) }

    private func toggle(_ set: inout Set<String>, _ id: String) {
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
