//
//  FileBrowserView.swift
//  CodexWorker
//
//  文件浏览与查看界面
//

import ComposableArchitecture
import Foundation
import SwiftUI

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
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Label("当前线程目录", systemImage: "folder.badge.gearshape")
                            .font(.subheadline.weight(.semibold))

                        Spacer()

                        Button {
                            viewStore.send(.goToParentDirectory)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(viewStore.currentPath == viewStore.effectiveRootPath)

                        Button {
                            viewStore.send(.refresh)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .padding(.horizontal, 14)

                    Text(viewStore.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)

                    HStack(spacing: 8) {
                        TextField(
                            "搜索当前目录",
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

                        Button("搜索") {
                            viewStore.send(.runSearch)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 14)

                    if let error = viewStore.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.footnote)
                            Spacer()
                            Button("关闭") {
                                viewStore.send(.clearError)
                            }
                            .font(.footnote)
                        }
                        .padding(.horizontal, 14)
                    }

                    List {
                        Section("目录") {
                            ForEach(viewStore.entries) { entry in
                                Button {
                                    viewStore.send(.entryTapped(entry))
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                            .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            if let modifiedAt = entry.modifiedAt {
                                                Text(modifiedAt)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if let size = entry.size {
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            if viewStore.canLoadMoreTree {
                                Button("加载更多目录项") {
                                    viewStore.send(.loadNextTreePage)
                                }
                            }

                            if viewStore.isLoadingTree {
                                HStack {
                                    ProgressView()
                                    Text("加载目录中...")
                                }
                            }
                        }

                        if viewStore.hasSearchQuery {
                            Section("搜索结果") {
                                if viewStore.searchResults.isEmpty, !viewStore.isSearching {
                                    Text("暂无匹配")
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(viewStore.searchResults) { match in
                                    Button {
                                        viewStore.send(.searchMatchTapped(match))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(match.path):\(match.line)")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Text(match.snippet)
                                                .font(.subheadline)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if viewStore.canLoadMoreSearch {
                                    Button("加载更多搜索结果") {
                                        viewStore.send(.loadMoreSearch)
                                    }
                                }

                                if viewStore.isSearching {
                                    HStack {
                                        ProgressView()
                                        Text("搜索中...")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
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
}

public struct FileViewerView: View {
    let store: StoreOf<FileViewerFeature>

    public init(store: StoreOf<FileViewerFeature>) {
        self.store = store
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 10) {
                    Text(viewStore.filePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)

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
                            Spacer()
                            Button("关闭") {
                                viewStore.send(.clearError)
                            }
                            .font(.footnote)
                        }
                        .padding(.horizontal, 12)
                    }

                    if viewStore.showDiff {
                        ScrollView {
                            Text(viewStore.diffPreview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 12)
                    } else if viewStore.isEditing {
                        TextEditor(
                            text: Binding(
                                get: { viewStore.content },
                                set: { viewStore.send(.contentChanged($0)) }
                            )
                        )
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
                        )
                        .padding(.horizontal, 12)
                    } else {
                        RunestoneCodeView(
                            content: viewStore.content,
                            language: viewStore.language,
                            focusLine: viewStore.focusLine
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
                        )
                        .padding(.horizontal, 12)
                    }

                    HStack(spacing: 10) {
                        Button {
                            viewStore.send(.setEditing(!viewStore.isEditing))
                        } label: {
                            Label(viewStore.isEditing ? "阅读" : "编辑", systemImage: viewStore.isEditing ? "doc.text" : "pencil")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewStore.showDiff)

                        Button {
                            viewStore.send(.toggleDiff(!viewStore.showDiff))
                        } label: {
                            Label(viewStore.showDiff ? "关闭 Diff" : "Diff", systemImage: "rectangle.split.3x1")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            viewStore.send(.openInTerminalTapped)
                        } label: {
                            Label("终端", systemImage: "terminal")
                        }
                        .buttonStyle(.bordered)

                        Menu {
                            if viewStore.revisions.isEmpty {
                                Text("暂无历史")
                            } else {
                                ForEach(viewStore.revisions, id: \.fetchedAtMs) { revision in
                                    Button {
                                        viewStore.send(.restoreRevision(revision))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(revision.etag)
                                                .font(.caption.monospaced())
                                            Text(Self.revisionDateText(revision.fetchedAtMs))
                                                .font(.caption2)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("历史", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            viewStore.send(.saveTapped)
                        } label: {
                            if viewStore.isSaving {
                                ProgressView()
                            } else {
                                Label("保存", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewStore.isDirty || viewStore.isSaving || !viewStore.isEditing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .navigationTitle(viewStore.filePath.split(separator: "/").last.map(String.init) ?? "文件")
                .navigationBarTitleDisplayMode(.inline)
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

    private static func revisionDateText(_ epochMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        return date.formatted(date: .numeric, time: .standard)
    }
}
