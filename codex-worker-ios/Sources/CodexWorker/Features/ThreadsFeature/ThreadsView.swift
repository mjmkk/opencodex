//
//  ThreadsView.swift
//  CodexWorker
//
//  线程列表视图（里程碑 2）
//

import ComposableArchitecture
import SwiftUI

public struct ThreadsView: View {
    let store: StoreOf<ThreadsFeature>

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
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

                Section("Threads") {
                    if viewStore.isLoading && viewStore.items.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在加载线程...")
                                .foregroundStyle(.secondary)
                        }
                    } else if viewStore.sortedItems.isEmpty {
                        Text("暂无线程")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewStore.sortedItems, id: \.threadId) { thread in
                            Button {
                                viewStore.send(.threadTapped(thread.threadId))
                            } label: {
                                ThreadRow(
                                    thread: thread,
                                    isSelected: viewStore.selectedThreadId == thread.threadId
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Threads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewStore.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            viewStore.send(.refresh)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear { viewStore.send(.onAppear) }
            .refreshable { viewStore.send(.refresh) }
        }
    }
}

private struct ThreadRow: View {
    let thread: Thread
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(thread.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let preview = thread.preview, !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("无预览内容")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            if let cwd = thread.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
