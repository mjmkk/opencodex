//
//  FileBrowserView.swift
//  CodexWorker
//
//  文件浏览与查看界面
//

import ComposableArchitecture
import Foundation
import MarkdownUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct FileBrowserView: View {
    let store: StoreOf<FileBrowserFeature>
    let onClose: (() -> Void)?

    public init(store: StoreOf<FileBrowserFeature>, onClose: (() -> Void)? = nil) {
        self.store = store
        self.onClose = onClose
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 12) {
                    browserHeader(viewStore)
                    searchPanel(viewStore)

                    if let error = viewStore.errorMessage {
                        errorBanner(error) {
                            viewStore.send(.clearError)
                        }
                        .padding(.horizontal, 14)
                    }

                    List {
                        Section {
                            if viewStore.entries.isEmpty, !viewStore.isLoadingTree {
                                ContentUnavailableView(
                                    "目录为空",
                                    systemImage: "folder",
                                    description: Text("该目录下暂无可浏览文件")
                                )
                                .frame(maxWidth: .infinity, alignment: .center)
                                .listRowBackground(Color.clear)
                            } else {
                                ForEach(sortedEntries(viewStore.entries)) { entry in
                                    Button {
                                        viewStore.send(.entryTapped(entry))
                                    } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                                .frame(width: 24)
                                                .padding(.top, 2)

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.name)
                                                    .font(.subheadline.weight(entry.isDirectory ? .semibold : .regular))
                                                    .lineLimit(1)

                                                HStack(spacing: 8) {
                                                    if let modifiedAt = entry.modifiedAt {
                                                        Text(modifiedAt)
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }

                                                    if let size = entry.size, !entry.isDirectory {
                                                        Text(humanReadableFileSize(size))
                                                            .font(.caption2.monospacedDigit())
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                            Spacer()
                                            if entry.isDirectory {
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.tertiary)
                                                    .padding(.top, 4)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if viewStore.canLoadMoreTree {
                                Button {
                                    viewStore.send(.loadNextTreePage)
                                } label: {
                                    Label("加载更多目录项", systemImage: "ellipsis.circle")
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }

                            if viewStore.isLoadingTree {
                                loadingInline("加载目录中...")
                            }
                        } header: {
                            HStack {
                                Text("目录")
                                Spacer()
                                Text("\(viewStore.entries.count) 项")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if viewStore.hasSearchQuery {
                            Section {
                                if viewStore.searchResults.isEmpty, !viewStore.isSearching {
                                    ContentUnavailableView(
                                        "暂无匹配",
                                        systemImage: "magnifyingglass",
                                        description: Text("尝试更换关键词或搜索范围")
                                    )
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .listRowBackground(Color.clear)
                                }

                                ForEach(viewStore.searchResults) { match in
                                    Button {
                                        viewStore.send(.searchMatchTapped(match))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "text.magnifyingglass")
                                                    .foregroundStyle(.blue)
                                                Text("\(match.path):\(match.line)")
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Text(match.snippet)
                                                .font(.subheadline)
                                                .lineLimit(3)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if viewStore.canLoadMoreSearch {
                                    Button {
                                        viewStore.send(.loadMoreSearch)
                                    } label: {
                                        Label("加载更多搜索结果", systemImage: "ellipsis.circle")
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                }

                                if viewStore.isSearching {
                                    loadingInline("搜索中...")
                                }
                            } header: {
                                HStack {
                                    Text("搜索结果")
                                    Spacer()
                                    Text("\(viewStore.searchResults.count) 条")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        viewStore.send(.refresh)
                    }
                }
                .navigationTitle("文件系统")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            onClose?()
                        }
                    }
                }
            }
            .onAppear {
                viewStore.send(.onAppear)
            }
            .sheet(
                isPresented: Binding(
                    get: { viewStore.viewer != nil },
                    set: { presented in
                        if !presented {
                            viewStore.send(.closeViewer)
                        }
                    }
                )
            ) {
                IfLetStore(
                    store.scope(state: \.viewer, action: \.viewer)
                ) { viewerStore in
                    FileViewerView(store: viewerStore)
                }
            }
        }
    }

    @ViewBuilder
    private func browserHeader(_ viewStore: ViewStore<FileBrowserFeature.State, FileBrowserFeature.Action>) -> some View {
        let breadcrumbs = buildBreadcrumbs(
            currentPath: viewStore.currentPath,
            rootPath: viewStore.effectiveRootPath
        )
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("当前线程目录", systemImage: "folder.badge.gearshape")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    viewStore.send(.goToParentDirectory)
                } label: {
                    Image(systemName: "arrow.up.backward")
                }
                .disabled(viewStore.currentPath == viewStore.effectiveRootPath)

                Button {
                    viewStore.send(.refresh)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(breadcrumbs) { crumb in
                        Button {
                            viewStore.send(.loadTree(path: crumb.fullPath, cursor: nil))
                        } label: {
                            Text(crumb.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(
                                    crumb.fullPath == viewStore.currentPath ? Color.white : Color.accentColor
                                )
                                .background(
                                    Capsule()
                                        .fill(
                                            crumb.fullPath == viewStore.currentPath
                                                ? Color.accentColor
                                                : Color.accentColor.opacity(0.15)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            Text(viewStore.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func searchPanel(_ viewStore: ViewStore<FileBrowserFeature.State, FileBrowserFeature.Action>) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    "搜索当前线程的文件内容",
                    text: viewStore.binding(
                        get: \.searchQuery,
                        send: FileBrowserFeature.Action.searchQueryChanged
                    )
                )
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit {
                    viewStore.send(.runSearch)
                }

                if viewStore.hasSearchQuery {
                    Button {
                        viewStore.send(.searchQueryChanged(""))
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button("搜索") {
                    viewStore.send(.runSearch)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func errorBanner(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer()
            Button("关闭") {
                onDismiss()
            }
            .font(.footnote.weight(.semibold))
        }
    }

    @ViewBuilder
    private func loadingInline(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }

    private func sortedEntries(_ entries: [FileTreeEntry]) -> [FileTreeEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func humanReadableFileSize(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func buildBreadcrumbs(currentPath: String, rootPath: String) -> [PathCrumb] {
        let normalizedRoot = rootPath
        let rootTitle = URL(fileURLWithPath: normalizedRoot).lastPathComponent.isEmpty
            ? normalizedRoot
            : URL(fileURLWithPath: normalizedRoot).lastPathComponent

        var crumbs: [PathCrumb] = [
            PathCrumb(title: rootTitle, fullPath: normalizedRoot)
        ]

        guard currentPath != normalizedRoot else {
            return crumbs
        }

        guard currentPath.hasPrefix(normalizedRoot) else {
            crumbs.append(PathCrumb(title: URL(fileURLWithPath: currentPath).lastPathComponent, fullPath: currentPath))
            return crumbs
        }

        let relative = String(currentPath.dropFirst(normalizedRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else {
            return crumbs
        }

        var running = normalizedRoot
        for part in relative.split(separator: "/").map(String.init) {
            running = (running as NSString).appendingPathComponent(part)
            crumbs.append(PathCrumb(title: part, fullPath: running))
        }
        return crumbs
    }

    private struct PathCrumb: Identifiable {
        let title: String
        let fullPath: String

        var id: String { fullPath }
    }
}

public struct FileViewerView: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: StoreOf<FileViewerFeature>
    private let markdownParser = MarkdownParserService.live
    private let codeSyntaxHighlighter: CodeSyntaxHighlighter = CodexCodeSyntaxHighlighter()

    public init(store: StoreOf<FileViewerFeature>) {
        self.store = store
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 10) {
                    fileMetaHeader(viewStore)

                    if let focusLine = viewStore.focusLine {
                        HStack(spacing: 6) {
                            Image(systemName: "scope")
                                .foregroundStyle(.blue)
                            Text("目标行：\(focusLine)")
                                .font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                    }

                    if let error = viewStore.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.footnote)
                                .lineLimit(3)
                            Spacer()
                            Button("关闭") {
                                viewStore.send(.clearError)
                            }
                            .font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                    }

                    Group {
                        if viewStore.showDiff {
                            ScrollView {
                                Text(viewStore.diffPreview)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .background(Color(uiColor: .secondarySystemBackground))
                        } else if viewStore.isEditing {
                            RunestoneCodeView(
                                content: viewStore.content,
                                language: viewStore.language,
                                focusLine: nil,
                                isEditable: true,
                                onContentChanged: { updatedContent in
                                    viewStore.send(.contentChanged(updatedContent))
                                }
                            )
                        } else if viewStore.isMarkdownDocument, viewStore.focusLine == nil {
                            markdownPreview(text: viewStore.content)
                        } else {
                            RunestoneCodeView(
                                content: viewStore.content,
                                language: viewStore.language,
                                focusLine: viewStore.focusLine,
                                isEditable: false
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
                }
                .navigationTitle(viewStore.filePath.split(separator: "/").last.map(String.init) ?? "文件")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    actionBar(viewStore)
                }
            }
            .onAppear {
                viewStore.send(.onAppear)
            }
            .overlay {
                if viewStore.isLoading {
                    ProgressView("加载文件中...")
                        .padding(18)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func fileMetaHeader(_ viewStore: ViewStore<FileViewerFeature.State, FileViewerFeature.Action>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text(viewStore.filePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                MetaChip(title: viewStore.language.uppercased(), icon: "chevron.left.forwardslash.chevron.right")
                MetaChip(title: "\(viewStore.totalLines) 行", icon: "number")
                if viewStore.isDirty {
                    MetaChip(title: "未保存", icon: "circle.fill", tint: .orange)
                }

                Spacer()
                Button {
                    copyToPasteboard(viewStore.filePath)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制文件路径")
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func actionBar(_ viewStore: ViewStore<FileViewerFeature.State, FileViewerFeature.Action>) -> some View {
        HStack(spacing: 10) {
            if viewStore.isEditing {
                Button {
                    viewStore.send(.cancelEditingTapped)
                } label: {
                    Label("取消", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewStore.send(.saveAndExitTapped)
                } label: {
                    if viewStore.isSaving {
                        ProgressView()
                    } else {
                        Label("完成", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewStore.isSaving)
            } else {
                Button {
                    viewStore.send(.setEditing(true))
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Button {
                        viewStore.send(.openInTerminalTapped)
                    } label: {
                        Label("在终端打开", systemImage: "terminal")
                    }

                    Button {
                        copyToPasteboard(viewStore.filePath)
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            if viewStore.isEditing && viewStore.isDirty {
                Text("未保存")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func copyToPasteboard(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
    }

    @ViewBuilder
    private func markdownPreview(text: String) -> some View {
        ScrollView {
            Markdown(markdownParser.parse(text).markdownContent)
                .markdownTheme(.gitHub)
                .tint(markdownLinkColor)
                .markdownTextStyle(\.text) {
                    ForegroundColor(.primary)
                    BackgroundColor(nil)
                }
                .markdownTextStyle(\.link) {
                    ForegroundColor(markdownLinkColor)
                    UnderlineStyle(.single)
                }
                .markdownTextStyle(\.code) {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.85))
                    BackgroundColor(previewInnerCodeColor)
                }
                .markdownBlockStyle(\.heading1) { configuration in
                    configuration.label
                        .markdownMargin(top: 8, bottom: 12)
                }
                .markdownBlockStyle(\.heading2) { configuration in
                    configuration.label
                        .markdownMargin(top: 6, bottom: 10)
                }
                .markdownBlockStyle(\.heading3) { configuration in
                    configuration.label
                        .markdownMargin(top: 4, bottom: 8)
                }
                .markdownBlockStyle(\.blockquote) { configuration in
                    configuration.label
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(previewQuoteBackgroundColor)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(previewBorderColor)
                                .frame(width: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .markdownMargin(top: 0, bottom: 12)
                }
                .markdownBlockStyle(\.codeBlock) { configuration in
                    ScrollView(.horizontal) {
                        configuration.label
                            .fixedSize(horizontal: false, vertical: true)
                            .relativeLineSpacing(.em(0.225))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.85))
                            }
                            .padding(12)
                    }
                    .background(previewInnerCodeColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(previewBorderColor, lineWidth: 0.8)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .markdownMargin(top: 0, bottom: 12)
                }
                .markdownBlockStyle(\.table) { configuration in
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTableBorderStyle(.init(color: previewBorderColor))
                        .markdownTableBackgroundStyle(
                            .alternatingRows(previewTableEvenRowColor, previewTableOddRowColor)
                        )
                        .markdownMargin(top: 0, bottom: 12)
                }
                .markdownCodeSyntaxHighlighter(codeSyntaxHighlighter)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var markdownLinkColor: Color {
        Color(uiColor: .link)
    }

    private var previewInnerCodeColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemBackground)
            : Color(uiColor: .secondarySystemBackground)
    }

    private var previewBorderColor: Color {
        Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.5 : 0.28)
    }

    private var previewQuoteBackgroundColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground).opacity(0.88)
            : Color(uiColor: .secondarySystemBackground).opacity(0.65)
    }

    private var previewTableEvenRowColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground).opacity(0.72)
            : Color(uiColor: .systemBackground).opacity(0.6)
    }

    private var previewTableOddRowColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemFill).opacity(0.92)
            : Color(uiColor: .secondarySystemFill).opacity(0.9)
    }

    private struct MetaChip: View {
        let title: String
        let icon: String
        var tint: Color = .secondary

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(Capsule())
        }
    }

    private static func revisionDateText(_ epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        return date.formatted(date: .numeric, time: .standard)
    }
}
