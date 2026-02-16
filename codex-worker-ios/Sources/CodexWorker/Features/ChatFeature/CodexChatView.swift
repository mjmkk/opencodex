//
//  CodexChatView.swift
//  CodexWorker
//
//  聊天视图（里程碑 3）
//

import ComposableArchitecture
import ExyteChat
import SwiftUI

public struct CodexChatView: View {
    let store: StoreOf<ChatFeature>
    let onSidebarTap: (() -> Void)?

    public init(
        store: StoreOf<ChatFeature>,
        onSidebarTap: (() -> Void)? = nil
    ) {
        self.store = store
        self.onSidebarTap = onSidebarTap
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            VStack(spacing: 0) {
                header(viewStore: viewStore)

                ChatView(
                    messages: viewStore.messages,
                    didSendMessage: { draft in
                        viewStore.send(.didSendDraft(draft))
                    }
                )
                .showDateHeaders(false)
                .showMessageTimeView(false)
                .keyboardDismissMode(.onDrag)
                .setAvailableInputs((viewStore.isApprovalLocked || viewStore.activeThread == nil) ? [] : [.text])
                .id(viewStore.activeThread?.threadId ?? "no-thread")
            }
            .onAppear { viewStore.send(.onAppear) }
            .onDisappear { viewStore.send(.onDisappear) }
        }
    }

    @ViewBuilder
    private func header(viewStore: ViewStoreOf<ChatFeature>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    onSidebarTap?()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.headline)
                }
                .buttonStyle(.plain)

                Text(viewStore.activeThread?.displayName ?? "未选择线程")
                    .font(.headline)
                Spacer()
                if viewStore.isStreaming {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if let state = viewStore.jobState {
                Text("任务状态：\(state.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewStore.isApprovalLocked {
                Text("检测到审批请求，输入已暂时锁定")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = viewStore.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }
}
