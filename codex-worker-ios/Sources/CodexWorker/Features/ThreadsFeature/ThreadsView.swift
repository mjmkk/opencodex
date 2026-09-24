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
    let executionAccessMode: ExecutionAccessMode
    let onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)?

    public init(
        store: StoreOf<ThreadsFeature>,
        onDismiss: (() -> Void)? = nil,
        executionAccessMode: ExecutionAccessMode = .defaultPermissions,
        onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)? = nil
    ) {
        self.store = store
        self.onDismiss = onDismiss
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
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(errorMessage)
                                    .font(.footnote)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if viewStore.isLoading && viewStore.items.isEmpty {
                        Section {
                            HStack {
                                ProgressView()
                                Text("正在加载线程...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if viewStore.items.isEmpty {
                        Section {
                            Text("暂无线程")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        switch viewStore.groupingMode {
                        case .byCwd:
                            ForEach(viewStore.cwdGroups) { group in
                                Section {
                                    ForEach(group.threads, id: \.threadId) { thread in
                                        threadButton(
                                            viewStore: viewStore,
                                            thread: thread,
                                            showCwd: false
                                        )
                                    }
                                } header: {
                                    CwdGroupHeader(
                                        group: group,
                                        isCreating: viewStore.isCreating,
                                        onCreateTapped: nil
                                    )
                                }
                            }

                        case .byTime:
                            let attention = viewStore.sortedItems.filter { $0.attentionReason != nil || viewStore.syncMetadata[$0.threadId]?.pinned == true }
                            if !attention.isEmpty {
                                Section("需要关注") {
                                    ForEach(attention, id: \.threadId) { thread in
                                        threadButton(viewStore: viewStore, thread: thread, showCwd: false)
                                    }
                                }
                            }
                            Section("最近任务") {
                                ForEach(viewStore.sortedItems.filter { thread in !attention.contains(where: { $0.threadId == thread.threadId }) }, id: \.threadId) { thread in
                                    threadButton(viewStore: viewStore, thread: thread, showCwd: false)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .listRowSpacing(6)
                .refreshable { viewStore.send(.refresh) }
            }
            .onAppear { viewStore.send(.onAppear) }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    @ViewBuilder
    private func header(viewStore: ViewStoreOf<ThreadsFeature>) -> some View {
        let selectedModeTint = executionAccessMode == .fullAccess ? Color.red : Color.blue
        let selectedThreadCwd = viewStore.items
            .first(where: { $0.threadId == viewStore.selectedThreadId })?
            .cwd

        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收起线程列表")
                }

                Text("任务")
                    .font(.title3.weight(.semibold))

                Spacer()

                if viewStore.isLoading {
                    ProgressView()
                } else {
                    Button {
                        viewStore.send(.refresh)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewStore.isCreating)
                    .accessibilityLabel("刷新线程列表")
                }

                Menu {
                    Picker("任务分组", selection: Binding(
                        get: { viewStore.groupingMode },
                        set: { viewStore.send(.groupingModeChanged($0)) })) {
                        Text("最近任务").tag(ThreadsFeature.GroupingMode.byTime)
                        Text("按目录分组").tag(ThreadsFeature.GroupingMode.byCwd)
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .accessibilityLabel("任务分组")

            }


        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func accessModeIconName(for mode: ExecutionAccessMode) -> String {
        switch mode {
        case .defaultPermissions:
            return "shield.fill"
        case .fullAccess:
            return "exclamationmark.shield.fill"
        }
    }

    private func accessModeTint(for mode: ExecutionAccessMode) -> Color {
        switch mode {
        case .defaultPermissions:
            return .blue
        case .fullAccess:
            return .red
        }
    }

    @ViewBuilder
    private func accessModePill(mode: ExecutionAccessMode, tint: Color) -> some View {
        accessModePillContent(mode: mode, tint: tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func accessModePillContent(mode: ExecutionAccessMode, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: accessModeIconName(for: mode))
                .foregroundStyle(tint)
            Text(mode.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(tint)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func threadButton(
        viewStore: ViewStoreOf<ThreadsFeature>,
        thread: Thread,
        showCwd: Bool
    ) -> some View {
        let isArchiving = viewStore.archivingThreadIds.contains(thread.threadId)

        Button {
            dismissKeyboard()
            viewStore.send(.threadTapped(thread.threadId))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
            ThreadRow(
                thread: thread,
                isSelected: viewStore.selectedThreadId == thread.threadId,
                showCwd: showCwd,
                isArchiving: isArchiving
            )
            .contentShape(Rectangle())
                HStack(spacing: 5) {
                    if viewStore.syncMetadata[thread.threadId]?.pinned == true { Image(systemName: "pin.fill") }
                    if (viewStore.syncMetadata[thread.threadId]?.unreadMessages ?? 0) > 0 { Text("有新内容").foregroundStyle(.blue) }
                    if let synced = viewStore.syncMetadata[thread.threadId]?.lastSyncedAt {
                        Text(MobileTime.ago(synced) + "同步")
                    } else { Text("本地内容 · 等待同步") }
                    if viewStore.syncMetadata[thread.threadId]?.isPartial == true { Text("部分历史") }
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread-" + thread.threadId)
        .disabled(isArchiving)
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                viewStore.send(.pinTapped(thread.threadId))
            } label: {
                Label(viewStore.syncMetadata[thread.threadId]?.pinned == true ? "取消持续展示" : "Pin 持续展示",
                      systemImage: viewStore.syncMetadata[thread.threadId]?.pinned == true ? "pin.slash" : "pin")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
    @Environment(\.colorScheme) private var colorScheme

    let thread: Thread
    let isSelected: Bool
    let showCwd: Bool
    let isArchiving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.listTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)

                Spacer()


                if thread.pendingRequestCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        if thread.pendingRequestCount > 1 {
                            Text("\(thread.pendingRequestCount)")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(Capsule())
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }

                if isArchiving {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let reason = thread.attentionReason {
                Text(reason).font(.caption).foregroundStyle(thread.pendingRequestCount > 0 ? .orange : .secondary)
            }
            if let relativeTime = thread.relativeTimeText {
                Text(relativeTime + "更新").font(.caption2).foregroundStyle(.secondary)
            }
            if let subtitle = thread.listSubtitle(showCwd: showCwd) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rowBackground: some View {
        isSelected ? Color.accentColor.opacity(0.09) : Color.clear
    }

    private var rowBorder: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.75 : 0.6)
        }
        return Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.5 : 0.24)
    }

    private var rowShadow: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.16)
        }
        return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.05)
    }
}

private struct CwdGroupHeader: View {
    let group: ThreadsFeature.State.CwdGroup
    let isCreating: Bool
    let onCreateTapped: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let onCreateTapped {
                    Button {
                        onCreateTapped()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                }
                Text("\(group.threads.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let fullPath = group.fullPath {
                Text(fullPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
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

    func listSubtitle(showCwd: Bool) -> String? {
        let normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let lines = normalized.split(whereSeparator: \.isNewline).map(String.init)
        if lines.count > 1 {
            return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized == listTitle ? nil : normalized
    }

    var relativeTimeText: String? {
        guard let date = lastActiveAt else { return nil }
        return MobileTime.ago(date)
    }
}
