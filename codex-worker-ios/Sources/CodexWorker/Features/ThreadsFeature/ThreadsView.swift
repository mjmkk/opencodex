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
                            VStack(alignment: .leading, spacing: 4) {
                                Label("操作未完成", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline.weight(.semibold))
                                Text(errorMessage)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !viewStore.items.isEmpty {
                                    Text("已保留当前任务列表")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityElement(children: .combine)
                        }
                    }

                    if (viewStore.isLoading || viewStore.isSyncing) && viewStore.items.isEmpty {
                        Section {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在读取任务…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                    } else if viewStore.items.isEmpty {
                        Section {
                            Text(viewStore.errorMessage == nil ? "暂无任务" : "任务暂不可用，请刷新重试")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44, alignment: .leading)
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
                                    CwdGroupHeader(group: group)
                                }
                            }

                        case .byTime:
                            let attention = viewStore.sortedItems.filter { $0.attentionReason != nil || viewStore.syncMetadata[$0.threadId]?.pinned == true }
                            if !attention.isEmpty {
                                Section {
                                    ForEach(attention, id: \.threadId) { thread in
                                        threadButton(viewStore: viewStore, thread: thread, showCwd: true)
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
                                        threadButton(viewStore: viewStore, thread: thread, showCwd: true)
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
                .listRowSpacing(0)
                .refreshable {
                    guard !viewStore.isLoading && !viewStore.isSyncing else { return }
                    viewStore.send(.refresh)
                }
            }
            .onAppear { viewStore.send(.onAppear) }
            .background(Color(uiColor: .systemBackground))
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

    @ViewBuilder
    private func threadButton(
        viewStore: ViewStoreOf<ThreadsFeature>,
        thread: Thread,
        showCwd: Bool
    ) -> some View {
        let isArchiving = viewStore.archivingThreadIds.contains(thread.threadId)
        let isSelected = viewStore.selectedThreadId == thread.threadId
        let metadata = viewStore.syncMetadata[thread.threadId]

        Button {
            dismissKeyboard()
            viewStore.send(.threadTapped(thread.threadId))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ThreadRow(
                    thread: thread,
                    isSelected: isSelected,
                    isArchiving: isArchiving
                )

                VStack(alignment: .leading, spacing: 4) {
                    if showCwd, let cwd = thread.cwd, !cwd.isEmpty {
                        Label(cwd, systemImage: "folder")
                    }
                    if let activityAt = thread.lastActiveAt {
                        Text("最后活动 · \(activityAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let syncedAt = metadata?.lastSyncedAt {
                        Text("上次同步 · \(syncedAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("本地内容 · 等待同步")
                    }
                    if metadata?.pinned == true {
                        Label("持续展示", systemImage: "pin.fill")
                    }
                    if (metadata?.unreadMessages ?? 0) > 0 {
                        Label("有新内容", systemImage: "circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    if metadata?.isPartial == true {
                        Label("部分历史", systemImage: "text.alignleft")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("打开此任务")
        .accessibilityIdentifier("thread-" + thread.threadId)
        .disabled(isArchiving)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .listRowSeparator(.visible)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : Color(uiColor: .systemBackground))
        .contextMenu {
            Button {
                viewStore.send(.pinTapped(thread.threadId))
            } label: {
                Label(metadata?.pinned == true ? "取消持续展示" : "Pin 持续展示",
                      systemImage: metadata?.pinned == true ? "pin.slash" : "pin")
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let thread: Thread
    let isSelected: Bool
    let isArchiving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.listTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }

                if isArchiving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("归档中")
                }
            }

            if let reason = thread.attentionReason {
                Label(reason, systemImage: attentionIcon)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(attentionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subtitle = thread.listSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var attentionIcon: String {
        if thread.pendingRequestCount > 0 { return "exclamationmark.circle" }
        switch thread.executionState {
        case "WAITING_APPROVAL": return "bubble.left.and.bubble.right"
        case "FAILED": return "exclamationmark.triangle"
        case "RUNNING": return "arrow.triangle.2.circlepath"
        case "QUEUED": return "clock"
        default: return "info.circle"
        }
    }

    private var attentionColor: Color {
        thread.pendingRequestCount > 0 || thread.executionState == "FAILED" ? .orange : .secondary
    }
}

private struct CwdGroupHeader: View {
    let group: ThreadsFeature.State.CwdGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            if let fullPath = group.fullPath {
                Text(fullPath)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
        let normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let lines = normalized.split(whereSeparator: \.isNewline).map(String.init)
        if lines.count > 1 {
            return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized == listTitle ? nil : normalized
    }
}
