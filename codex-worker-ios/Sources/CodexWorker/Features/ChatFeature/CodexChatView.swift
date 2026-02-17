//
//  CodexChatView.swift
//  CodexWorker
//
//  聊天视图（里程碑 3）
//

import ComposableArchitecture
import ExyteChat
import MarkdownUI
import SwiftUI

public struct CodexChatView: View {
    let store: StoreOf<ChatFeature>
    let connectionState: ConnectionState
    let onSidebarTap: (() -> Void)?
    let onSettingsTap: (() -> Void)?
    let executionAccessMode: ExecutionAccessMode
    let onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)?
    private let renderPipeline: MessageRenderPipeline
    private let codeSyntaxHighlighter: CodeSyntaxHighlighter
    private let chatBackgroundColor = Color(uiColor: .systemGroupedBackground)

    public init(
        store: StoreOf<ChatFeature>,
        connectionState: ConnectionState = .disconnected,
        onSidebarTap: (() -> Void)? = nil,
        onSettingsTap: (() -> Void)? = nil,
        executionAccessMode: ExecutionAccessMode = .defaultPermissions,
        onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)? = nil,
        renderPipeline: MessageRenderPipeline = .live,
        codeSyntaxHighlighter: CodeSyntaxHighlighter = CodexCodeSyntaxHighlighter()
    ) {
        self.store = store
        self.connectionState = connectionState
        self.onSidebarTap = onSidebarTap
        self.onSettingsTap = onSettingsTap
        self.executionAccessMode = executionAccessMode
        self.onExecutionAccessModeChanged = onExecutionAccessModeChanged
        self.renderPipeline = renderPipeline
        self.codeSyntaxHighlighter = codeSyntaxHighlighter
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            VStack(spacing: 0) {
                header(viewStore: viewStore)

                if viewStore.shouldShowGeneratingIndicator {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("正在生成...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                }

                ChatView(
                    messages: viewStore.messages,
                    didSendMessage: { draft in
                        viewStore.send(.didSendDraft(draft))
                    },
                    messageBuilder: { message, _, _, _, _, _, _ in
                        CodexMessageBubble(
                            message: message,
                            renderPipeline: renderPipeline,
                            codeSyntaxHighlighter: codeSyntaxHighlighter
                        )
                    }
                )
                .showDateHeaders(false)
                .showMessageTimeView(false)
                .keyboardDismissMode(.onDrag)
                .setAvailableInputs((viewStore.isApprovalLocked || viewStore.activeThread == nil) ? [] : [.text])
                .id(viewStore.activeThread?.threadId ?? "no-thread")
            }
            .background(chatBackgroundColor)
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

                Menu {
                    ForEach(ExecutionAccessMode.allCases, id: \.self) { mode in
                        Button {
                            onExecutionAccessModeChanged?(mode)
                        } label: {
                            HStack {
                                Text(mode.title)
                                Spacer()
                                if mode == executionAccessMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                        Text(executionAccessMode.title)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
                }
                .disabled(viewStore.isSending || viewStore.isStreaming)

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

private struct CodexMessageBubble: View {
    let message: Message
    let renderPipeline: MessageRenderPipeline
    let codeSyntaxHighlighter: CodeSyntaxHighlighter
    private let assistantBubbleColor = Color(uiColor: .secondarySystemGroupedBackground)
    private let assistantInnerCodeColor = Color(uiColor: .tertiarySystemFill)
    private let assistantBorderColor = Color(uiColor: .separator).opacity(0.2)
    private let assistantTableEvenRowColor = Color(uiColor: .systemBackground).opacity(0.35)
    private let assistantTableOddRowColor = Color(uiColor: .tertiarySystemFill).opacity(0.75)

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.user.isCurrentUser {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: 280, alignment: .trailing)

                    if let style = statusStyle(message.status) {
                        Image(systemName: style.icon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(style.tint)
                    }
                }
            } else {
                let rendered = renderPipeline.render(message.text)
                VStack(alignment: .leading, spacing: 0) {
                    Markdown(rendered.markdownContent)
                        .markdownTheme(.gitHub)
                        .markdownTextStyle(\.text) {
                            ForegroundColor(.primary)
                            BackgroundColor(nil)
                        }
                        .markdownTextStyle(\.code) {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                            BackgroundColor(assistantInnerCodeColor)
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
                            .background(assistantInnerCodeColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .markdownMargin(top: 0, bottom: 12)
                        }
                        .markdownBlockStyle(\.table) { configuration in
                            configuration.label
                                .fixedSize(horizontal: false, vertical: true)
                                .markdownTableBorderStyle(.init(color: assistantBorderColor))
                                .markdownTableBackgroundStyle(
                                    .alternatingRows(assistantTableEvenRowColor, assistantTableOddRowColor)
                                )
                                .markdownMargin(top: 0, bottom: 12)
                        }
                        .markdownCodeSyntaxHighlighter(codeSyntaxHighlighter)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(assistantBubbleColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(assistantBorderColor, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if let hint = rendered.compatibilityHint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .padding(.horizontal, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func statusStyle(_ status: Message.Status?) -> (icon: String, tint: Color)? {
        guard let status else { return nil }
        switch status {
        case .sending:
            return ("clock", .secondary)
        case .sent:
            return ("checkmark.circle.fill", .green)
        case .delivered:
            return ("checkmark.circle.fill", .green)
        case .read:
            return ("checkmark.circle.fill", .blue)
        case .error:
            return ("exclamationmark.circle.fill", .red)
        }
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
