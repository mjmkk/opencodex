//
//  ThreadsView.swift
//  CodexWorker
//
//  线程列表视图（里程碑 2）
//

import ComposableArchitecture
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct ThreadsView: View {
    let store: StoreOf<ThreadsFeature>
    let onDismiss: (() -> Void)?
    let onSettingsTap: (() -> Void)?
    let onOverviewTap: (() -> Void)?
    let onInboxTap: (() -> Void)?
    let executionAccessMode: ExecutionAccessMode
    let onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)?
    @State private var informationSelection: ThreadInformationSelection?

    public init(
        store: StoreOf<ThreadsFeature>,
        onDismiss: (() -> Void)? = nil,
        onSettingsTap: (() -> Void)? = nil,
        onOverviewTap: (() -> Void)? = nil,
        onInboxTap: (() -> Void)? = nil,
        executionAccessMode: ExecutionAccessMode = .defaultPermissions,
        onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)? = nil
    ) {
        self.store = store
        self.onDismiss = onDismiss
        self.onSettingsTap = onSettingsTap
        self.onOverviewTap = onOverviewTap
        self.onInboxTap = onInboxTap
        self.executionAccessMode = executionAccessMode
        self.onExecutionAccessModeChanged = onExecutionAccessModeChanged
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            VStack(spacing: 0) {
                header(viewStore: viewStore)

                Divider()

                List {
                    if let errorMessage = viewStore.errorMessage {
                        Section {
                            failureContent(viewStore: viewStore, errorMessage: errorMessage)
                                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                                .listRowSeparator(.hidden)
                        }
                    }

                    if (viewStore.isLoading || viewStore.isSyncing) && viewStore.items.isEmpty && viewStore.errorMessage == nil {
                        Section {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在读取任务…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                    } else if viewStore.items.isEmpty && viewStore.errorMessage == nil {
                        Section {
                            CodexEmptyState(title: "尚无显示的任务", detail: viewStore.errorMessage == nil ? "刷新任务目录，核对已有工作的当前内容。" : "读取暂未完成；这不代表你的任务为空。", symbol: "rectangle.stack")
                                .listRowSeparator(.hidden)

                        }
                    } else {
                        switch viewStore.groupingMode {
                        case .byCwd:
                            ForEach(viewStore.cwdGroups) { group in
                                Section {
                                    ForEach(group.threads, id: \.threadId) { thread in
                                        threadButton(viewStore: viewStore, thread: thread)
                                    }
                                } header: {
                                    CwdGroupHeader(group: group)
                                }
                            }

                        case .byTime:
                            let attention = viewStore.sortedItems.filter { $0.attentionReason != nil || viewStore.syncMetadata[$0.threadId]?.pinned == true }
                            if !attention.isEmpty {
                                Section {
                                    ForEach(attention, id: \.threadId) { thread in
                                        threadButton(viewStore: viewStore, thread: thread)
                                    }
                                } header: {
                                    sectionHeading("需要关注")
                                }
                            }
                            let recent = viewStore.sortedItems.filter { thread in
                                !attention.contains(where: { $0.threadId == thread.threadId })
                            }
                            if !recent.isEmpty {
                                Section {
                                    ForEach(recent, id: \.threadId) { thread in
                                        threadButton(viewStore: viewStore, thread: thread)
                                    }
                                } header: {
                                    sectionHeading("最近任务")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .listRowSpacing(0)
                .refreshable {
                    guard !viewStore.isLoading && !viewStore.isSyncing else { return }
                    viewStore.send(.refresh)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if onOverviewTap != nil || onInboxTap != nil {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 0) {
                            if let onOverviewTap { destinationButton("目标总览", action: onOverviewTap) }
                            if let onInboxTap { destinationButton("待你处理", action: onInboxTap) }
                            if let onSettingsTap { destinationButton("连接设置", action: onSettingsTap) }
                        }.padding(.horizontal, 8)
                    }.background(CodexAppearance.canvas)
                }
            }
            .onAppear { viewStore.send(.onAppear) }
            .background(Color(uiColor: .systemBackground))
            .sheet(item: $informationSelection) { selection in
                WithViewStore(store, observe: {
                    ThreadInformationSnapshot(state: $0, id: selection.id)
                }) { snapshot in
                    if let thread = snapshot.thread {
                        ThreadInformationView(thread: thread, metadata: snapshot.metadata)
                    } else {
                        NavigationStack {
                            ContentUnavailableView("任务已不在当前列表", systemImage: "doc.text.magnifyingglass",
                                description: Text("返回任务目录后重新选择。当前信息已失效。"))
                                .navigationTitle("任务信息")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("关闭") { informationSelection = nil }
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private func destinationButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }

    private func failureContent(viewStore: ViewStoreOf<ThreadsFeature>, errorMessage: String) -> some View {
        let isRefreshing = viewStore.isLoading || viewStore.isSyncing
        let needsSettings = viewStore.needsConnectionSettings && onSettingsTap != nil
        return VStack(alignment: .leading, spacing: 12) {
            Label("任务目录未能更新", systemImage: "exclamationmark.circle")
                .font(.body.weight(.medium))
            Text(recoveryHint(viewStore))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if needsSettings, let onSettingsTap {
                Button("连接与设置", action: onSettingsTap)
                    .buttonStyle(CodexPrimaryButtonStyle())
                Button { viewStore.send(.refresh) } label: { retryLabel(isRefreshing: isRefreshing) }
                    .buttonStyle(.plain).font(.footnote)
                    .disabled(isRefreshing)
            } else {
                Button { viewStore.send(.refresh) } label: { retryLabel(isRefreshing: isRefreshing) }
                    .buttonStyle(CodexPrimaryButtonStyle()).disabled(isRefreshing)
                if let onSettingsTap {
                    Button("连接与设置", action: onSettingsTap)
                        .buttonStyle(.plain).font(.footnote).frame(minHeight: 44)
                }
            }
            DisclosureGroup("查看失败原因") {
                Text(errorMessage).font(.footnote).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.footnote).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func retryLabel(isRefreshing: Bool) -> some View {
        HStack(spacing: 8) {
            if isRefreshing { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise") }
            Text(isRefreshing ? "正在读取…" : "重新读取")
        }.frame(minHeight: 44)
    }

    private func recoveryHint(_ viewStore: ViewStoreOf<ThreadsFeature>) -> String {
        switch viewStore.failure {
        case .secureConnectionRequired:
            return "系统已阻止 HTTP 连接，请在设置中核对服务的 HTTPS 地址。"
        case .unauthorized:
            return "访问验证未通过，请核对连接凭据。已有内容会保留。"
        case .notConfigured:
            return "先填写服务地址，再读取任务目录。"
        default:
            return viewStore.items.isEmpty ? "当前任务尚未确认，可以重新读取或检查连接。" : "已保留上次任务列表，可以重新读取。"
        }
    }

    private func header(viewStore: ViewStoreOf<ThreadsFeature>) -> some View {
        let isRefreshing = viewStore.isLoading || viewStore.isSyncing

        return HStack(spacing: 0) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "sidebar.leading")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起任务列表")
            }

            Text("任务")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 8)

            Spacer(minLength: 8)

            if viewStore.errorMessage == nil {
              Button {
                viewStore.send(.refresh)
              } label: {
                ZStack {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.medium))
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewStore.isCreating || isRefreshing)
            .accessibilityLabel(isRefreshing ? "正在刷新任务列表" : "刷新任务列表")
            }

            Menu {
                Picker("任务分组", selection: Binding(
                    get: { viewStore.groupingMode },
                    set: { viewStore.send(.groupingModeChanged($0)) })) {
                    Text("最近任务").tag(ThreadsFeature.GroupingMode.byTime)
                    Text("按目录分组").tag(ThreadsFeature.GroupingMode.byCwd)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.body.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("任务分组")
            .accessibilityValue(viewStore.groupingMode.title)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.vertical, 4)
    }

    private func threadButton(
        viewStore: ViewStoreOf<ThreadsFeature>,
        thread: Thread
    ) -> some View {
        let isArchiving = viewStore.archivingThreadIds.contains(thread.threadId)
        let isSelected = viewStore.selectedThreadId == thread.threadId
        let metadata = viewStore.syncMetadata[thread.threadId]

        return HStack(alignment: .top, spacing: 0) {
            Button {
                dismissKeyboard()
                viewStore.send(.threadTapped(thread.threadId))
            } label: {
                ThreadRow(
                    thread: thread,
                    metadata: metadata,
                    isSelected: isSelected,
                    isArchiving: isArchiving
                )
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint("打开此任务")
            .accessibilityIdentifier("thread-" + thread.threadId)
            .accessibilityAction(named: Text("任务信息")) {
                informationSelection = ThreadInformationSelection(id: thread.id)
            }

            Button {
                informationSelection = ThreadInformationSelection(id: thread.id)
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("任务信息：" + thread.listTitle)
            .accessibilityIdentifier("thread-info-" + thread.threadId)
        }
        .buttonStyle(.plain)
        .disabled(isArchiving)
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 16))
        .listRowSeparator(.visible)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.06) : Color(uiColor: .systemBackground))
        .contextMenu {
            Button {
                informationSelection = ThreadInformationSelection(id: thread.id)
            } label: {
                Label("任务信息", systemImage: "info.circle")
            }
            Button {
                viewStore.send(.pinTapped(thread.threadId))
            } label: {
                Label(metadata?.pinned == true ? "取消持续展示" : "Pin 持续展示",
                      systemImage: metadata?.pinned == true ? "pin.slash" : "pin")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // The mirror reader does not declare an archive capability for its owner.
            if !thread.hasCachedSource {
            Button(role: .destructive) {
                viewStore.send(.archiveTapped(thread.threadId))
            } label: {
                if isArchiving {
                    Label("归档中", systemImage: "hourglass")
                } else {
                    Label("归档", systemImage: "archivebox.fill")
                }
            }
            .disabled(isArchiving)
            }
        }
    }
}

private struct ThreadInformationSelection: Identifiable {
    let id: String
}

/// Resolve both pieces from the same current State, including while the sheet is open.
private struct ThreadInformationSnapshot: Equatable {
    let thread: Thread?
    let metadata: ThreadSyncMetadata?

    init(state: ThreadsFeature.State, id: String) {
        let current = state.items.first { $0.id == id }
        thread = current
        metadata = current.flatMap { state.syncMetadata[$0.threadId] }
    }
}

private func dismissKeyboard() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
#endif
}

private struct ThreadRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let thread: Thread
    let metadata: ThreadSyncMetadata?
    let isSelected: Bool
    let isArchiving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.listTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                if (metadata?.unreadMessages ?? 0) > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("\(metadata?.unreadMessages ?? 0) 条未读内容")
                }
                if metadata?.pinned == true {
                    Image(systemName: "pin.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已启用持续展示")
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                if isArchiving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("归档中")
                }
            }

            if let subtitle = thread.listSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary != nil || thread.lastActiveAt != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let summary { summary.fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 0)
                    if let activityAt = thread.lastActiveAt {
                        Text(ThreadListDate.shortActivity(activityAt))
                            .foregroundStyle(.secondary).monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(.footnote)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summaryAccessibilityLabel)
            }
        }
    }

    private var summary: Text? {
        var parts: [Text] = []
        if let reason = thread.attentionReason {
            parts.append(Text(reason).foregroundColor(attentionColor))
        }
        if metadata == nil {
            parts.append(Text("同步未知").foregroundColor(Color(uiColor: .secondaryLabel)))
        } else if metadata?.lastSyncedAt == nil {
            parts.append(Text("待同步").foregroundColor(Color(uiColor: .secondaryLabel)))
        }
        if metadata?.isPartial == true {
            parts.append(Text("部分历史").foregroundColor(Color(uiColor: .secondaryLabel)))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ").foregroundColor(Color(uiColor: .secondaryLabel)) + $1 }
    }

    private var summaryAccessibilityLabel: String {
        var parts = [thread.attentionReason].compactMap { $0 }
        if metadata == nil { parts.append("同步记录未知") }
        else if metadata?.lastSyncedAt == nil { parts.append("本地内容，等待同步") }
        if metadata?.isPartial == true { parts.append("部分历史") }
        if let activityAt = thread.lastActiveAt {
            parts.append("最后活动：" + ThreadListDate.full(activityAt))
        }
        return parts.joined(separator: "，")
    }

    private var attentionColor: Color {
        thread.pendingRequestCount > 0 || thread.executionState == "FAILED" ? .orange : Color(uiColor: .secondaryLabel)
    }
}

private struct CwdGroupHeader: View {
    let group: ThreadsFeature.State.CwdGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(group.title, systemImage: "folder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("\(group.threads.count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ThreadInformationView: View {
    @Environment(\.dismiss) private var dismiss

    let thread: Thread
    let metadata: ThreadSyncMetadata?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(thread.listTitle)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        if let reason = thread.attentionReason {
                            Text(reason)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    informationHeading("任务记录")
                    informationField("最后活动", value: thread.lastActiveAt.map(ThreadListDate.full) ?? "时间未知")
                    informationField("上次同步", value: metadata == nil ? "同步记录未知" : (metadata?.lastSyncedAt.map(ThreadListDate.full) ?? "本地内容 · 等待同步"))
                    if metadata?.isPartial == true {
                        Label("部分历史", systemImage: "text.alignleft")
                            .font(.body)
                            .listRowInsets(informationInsets)
                    }
                    informationField("工作目录", value: thread.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? "未提供目录")
                    DisclosureGroup("任务身份与来源") {
                        sourceField("任务标识", value: thread.threadId)
                        sourceField("来源命名空间", value: thread.origin?.namespace ?? "原始任务来源未提供")
                        if let device = thread.sourceDevice { sourceField("来源设备", value: device) }
                    }
                    .listRowInsets(informationInsets)
                } footer: {
                    Text("活动时间来自任务本身；同步时间只表示本地内容的同步记录，两者不同。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    informationHeading("本地记录")
                    informationField("未读内容", value: metadata.map { String($0.unreadMessages) } ?? "未知")
                    informationField("持续展示", value: metadata.map { $0.pinned ? "已启用" : "未启用" } ?? "状态未知")
                }

                if let preview = thread.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    Section {
                        informationHeading("内容预览")
                        Text(preview)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CodexAppearance.canvas)
            .tint(.primary)
            .navigationTitle("任务信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("关闭任务信息")
                }
            }
        }
    }

    private var informationInsets: EdgeInsets {
        EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
    }

    private func informationHeading(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))
            .listRowSeparator(.hidden)
    }

    private func informationField(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.footnote).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Text(value).font(.body).fixedSize().textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Text(value).font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .listRowInsets(informationInsets)
        .accessibilityElement(children: .combine)
    }

    private func sourceField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }.padding(.vertical, 4)
    }
}

private enum ThreadListDate {
    private static let locale = Locale(identifier: "zh_CN")

    static func shortActivity(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 " + date.formatted(.dateTime.locale(locale).hour().minute())
        }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.locale(locale).month().day())
        }
        return date.formatted(.dateTime.locale(locale).year().month().day())
    }

    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).year().month(.twoDigits).day(.twoDigits).hour().minute().second())
            + "（" + TimeZone.current.identifier + "）"
    }
}

private extension Thread {
    var listTitle: String {
        if let name, !name.isEmpty { return name }
        let normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty {
            return normalized
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? normalized
        }
        return displayName == "Untitled" ? "新对话" : displayName
    }

    var listSubtitle: String? {
        var normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        // Preview only: preserve the full source body in the conversation.
        if normalized.hasPrefix("<heartbeat>"),
           let range = normalized.range(of: "(?s)(?<=<message>).*?(?=</message>)", options: .regularExpression) {
            normalized = String(normalized[range])
        }
        normalized = normalized.replacingOccurrences(of: "::chatgpt-content-reference\\{[^}]*\\}",
            with: "引用内容", options: .regularExpression)
        if let text = try? AttributedString(markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            normalized = String(text.characters)
        }
        guard normalized != listTitle else { return nil }
        let lines = normalized.split(whereSeparator: \.isNewline).map(String.init)
        if name == nil || name?.isEmpty == true {
            let remainder = lines.dropFirst().joined(separator: " ")
            return remainder.isEmpty ? nil : remainder
        }
        return lines.joined(separator: " ")
    }
}
