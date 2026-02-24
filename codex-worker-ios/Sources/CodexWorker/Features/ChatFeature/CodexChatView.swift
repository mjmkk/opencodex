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
    @Environment(\.colorScheme) private var colorScheme

    private struct ViewState: Equatable {
        let activeThreadId: String?
        let activeThreadTitle: String
        let messages: [Message]
        let shouldShowGeneratingIndicator: Bool
        let isApprovalLocked: Bool
        let jobState: JobState?
        let errorMessage: String?
        let isSending: Bool
        let isStreaming: Bool
        let canInput: Bool

        init(_ state: ChatFeature.State) {
            self.activeThreadId = state.activeThread?.threadId
            self.activeThreadTitle = state.activeThread?.displayName ?? "未选择线程"
            self.messages = state.messages
            self.shouldShowGeneratingIndicator = state.shouldShowGeneratingIndicator
            self.isApprovalLocked = state.isApprovalLocked
            self.jobState = state.jobState
            self.errorMessage = state.errorMessage
            self.isSending = state.isSending
            self.isStreaming = state.isStreaming
            self.canInput = state.activeThread != nil && !state.isApprovalLocked
        }
    }

    let store: StoreOf<ChatFeature>
    let connectionState: ConnectionState
    let onSidebarTap: (() -> Void)?
    let onSettingsTap: (() -> Void)?
    let executionAccessMode: ExecutionAccessMode
    let onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)?
    private let renderPipeline: MessageRenderPipeline
    private let codeSyntaxHighlighter: CodeSyntaxHighlighter

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
        WithViewStore(store, observe: ViewState.init) { viewStore in
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
                    .background(chatSecondaryBackgroundColor)
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
                            codeSyntaxHighlighter: codeSyntaxHighlighter,
                            colorScheme: colorScheme
                        )
                    }
                )
                .showDateHeaders(false)
                .showMessageTimeView(false)
                .keyboardDismissMode(.onDrag)
                .setAvailableInputs(viewStore.canInput ? [.text] : [])
                .id(viewStore.activeThreadId ?? "no-thread")
                .chatTheme(
                    colors: ChatTheme.Colors(
                        mainBG: chatMainBackgroundColor,
                        mainTint: chatSecondaryTextColor,
                        messageMyBG: .accentColor,
                        messageMyText: .white,
                        inputBG: chatElevatedInputColor,
                        inputText: chatPrimaryTextColor,
                        inputPlaceholderText: chatSecondaryTextColor,
                        inputSignatureBG: chatElevatedInputColor,
                        inputSignatureText: chatPrimaryTextColor,
                        inputSignaturePlaceholderText: chatSecondaryTextColor,
                        menuBG: chatSecondaryBackgroundColor,
                        sendButtonBackground: .accentColor
                    )
                )
            }
            .background(pageBackgroundColor)
            .onAppear { viewStore.send(.onAppear) }
            .onDisappear { viewStore.send(.onDisappear) }
        }
    }

    private var pageBackgroundColor: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var chatMainBackgroundColor: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var chatSecondaryBackgroundColor: Color {
        Color(uiColor: .secondarySystemBackground)
    }

    private var chatElevatedInputColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemBackground)
            : Color(uiColor: .systemBackground)
    }

    private var chatPrimaryTextColor: Color {
        Color(uiColor: .label)
    }

    private var chatSecondaryTextColor: Color {
        Color(uiColor: .secondaryLabel)
    }

    @ViewBuilder
    private func header(viewStore: ViewStore<ViewState, ChatFeature.Action>) -> some View {
        let selectedModeTint = executionAccessMode == .fullAccess ? Color.red : Color.blue

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    onSidebarTap?()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开线程列表")

                Text(viewStore.activeThreadTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
                Spacer()
                ConnectionStateBadge(state: connectionState)

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
                .layoutPriority(0)
                .disabled(viewStore.isSending || viewStore.isStreaming)

                Button {
                    onSettingsTap?()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开设置")
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
        .background(chatSecondaryBackgroundColor)
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
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
        .layoutPriority(-1)
    }

    @ViewBuilder
    private func accessModePillContent(mode: ExecutionAccessMode, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: accessModeIconName(for: mode))
                .foregroundStyle(tint)
            Text(mode.title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(tint)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(tint)
        }
    }
}

private struct CodexMessageBubble: View {
    let message: Message
    let renderPipeline: MessageRenderPipeline
    let codeSyntaxHighlighter: CodeSyntaxHighlighter
    let colorScheme: ColorScheme

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
                                .stroke(assistantBorderColor, lineWidth: 0.8)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: assistantShadowColor, radius: 1.5, x: 0, y: 1)

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

    private var assistantBubbleColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(uiColor: .systemBackground)
    }

    private var assistantInnerCodeColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemBackground)
            : Color(uiColor: .secondarySystemBackground)
    }

    private var assistantBorderColor: Color {
        Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.5 : 0.28)
    }

    private var assistantShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.24 : 0.05)
    }

    private var assistantTableEvenRowColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground).opacity(0.72)
            : Color(uiColor: .systemBackground).opacity(0.6)
    }

    private var assistantTableOddRowColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemFill).opacity(0.92)
            : Color(uiColor: .secondarySystemFill).opacity(0.9)
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
