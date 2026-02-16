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
    let connectionState: ConnectionState
    let onSidebarTap: (() -> Void)?
    let onSettingsTap: (() -> Void)?

    public init(
        store: StoreOf<ChatFeature>,
        connectionState: ConnectionState = .disconnected,
        onSidebarTap: (() -> Void)? = nil,
        onSettingsTap: (() -> Void)? = nil
    ) {
        self.store = store
        self.connectionState = connectionState
        self.onSidebarTap = onSidebarTap
        self.onSettingsTap = onSettingsTap
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
                ConnectionStateBadge(state: connectionState)

                if viewStore.isStreaming {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Button {
                    onSettingsTap?()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.headline)
                }
                .buttonStyle(.plain)
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

private struct ConnectionStateBadge: View {
    let state: ConnectionState

    private var compactText: String {
        switch state {
        case .connected:
            return "可达"
        case .connecting, .reconnecting:
            return "检测中"
        case .failed, .disconnected:
            return "不可达"
        }
    }

    private var tint: Color {
        switch state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .failed, .disconnected:
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(compactText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel("网络状态\(compactText)")
    }
}
