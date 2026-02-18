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

                Picker(
                    "线程分组方式",
                    selection: Binding(
                        get: { viewStore.groupingMode },
                        set: { viewStore.send(.groupingModeChanged($0)) }
                    )
                ) {
                    ForEach(ThreadsFeature.GroupingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

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
                                    CwdGroupHeader(group: group)
                                }
                            }

                        case .byTime:
                            Section("最近对话") {
                                ForEach(viewStore.sortedItems, id: \.threadId) { thread in
                                    threadButton(
                                        viewStore: viewStore,
                                        thread: thread,
                                        showCwd: true
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { viewStore.send(.refresh) }
            }
            .onAppear { viewStore.send(.onAppear) }
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func header(viewStore: ViewStoreOf<ThreadsFeature>) -> some View {
        let selectedModeTint = executionAccessMode == .fullAccess ? Color.red : Color.blue

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
                }

                Text("Threads")
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
                }

                if viewStore.isCreating {
                    ProgressView()
                } else {
                    Button {
                        viewStore.send(.createTapped)
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewStore.isLoading)
                }
            }

            HStack(spacing: 8) {
                Label("权限", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    ForEach(ExecutionAccessMode.allCases, id: \.self) { mode in
                        Button {
                            onExecutionAccessModeChanged?(mode)
                        } label: {
                            HStack {
                                Image(systemName: accessModeIconName(for: mode))
                                    .foregroundStyle(accessModeTint(for: mode))
                                Text(mode.title)
                                    .lineLimit(1)
                                    .foregroundStyle(accessModeTint(for: mode))
                                Spacer()
                                if mode == executionAccessMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    accessModePill(mode: executionAccessMode, tint: selectedModeTint)
                }
            }
            .padding(.horizontal, 2)
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
            ThreadRow(
                thread: thread,
                isSelected: viewStore.selectedThreadId == thread.threadId,
                showCwd: showCwd,
                isArchiving: isArchiving
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isArchiving)
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
    let thread: Thread
    let isSelected: Bool
    let showCwd: Bool
    let isArchiving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.listTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if let relativeTime = thread.relativeTimeText {
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if thread.pendingApprovalCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        if thread.pendingApprovalCount > 1 {
                            Text("\(thread.pendingApprovalCount)")
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
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if isArchiving {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let subtitle = thread.listSubtitle(showCwd: showCwd) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct CwdGroupHeader: View {
    let group: ThreadsFeature.State.CwdGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
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
        if showCwd {
            let normalizedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedCwd.isEmpty {
                return normalizedCwd
            }
        }

        let normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let lines = normalized.split(whereSeparator: \.isNewline).map(String.init)
        if lines.count > 1 {
            return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    var relativeTimeText: String? {
        guard let date = lastActiveAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
