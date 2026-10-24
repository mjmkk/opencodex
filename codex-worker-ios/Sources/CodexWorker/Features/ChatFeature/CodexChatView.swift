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
#if canImport(UIKit)
import UIKit
#endif

public struct CodexChatView: View {
    @State private var showActivities = false
    @State private var showIdentity = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct ViewState: Equatable {
        let activeThreadId: String?
        let identity: String?
        let activeThreadTitle: String
        let inputText: String
        let hasUnconfirmedReply: Bool
        let messages: [Message]
        let errorMessage: String?
        let isSending: Bool
        let canInput: Bool
        let canEdit: Bool
        let hasCachedSource: Bool
        let sourceDevice: String?
        let history: ThreadHistory?
        let lastSyncedAt: Date?
        let isHistorySyncing: Bool
        let hasNativeReviewWait: Bool
        init(_ state: ChatFeature.State) {
            activeThreadId = state.activeThread?.threadId; identity = state.activeThread?.id
            activeThreadTitle = state.activeThread?.displayName ?? "未选择任务"
            inputText = state.inputText; hasUnconfirmedReply = state.hasUnconfirmedReply
            messages = state.messages; errorMessage = state.errorMessage; isSending = state.isSending
            canInput = state.canSend; canEdit = state.activeThread != nil && !state.isSending && !state.hasUnconfirmedReply
            hasCachedSource = state.activeThread?.hasCachedSource == true; sourceDevice = state.activeThread?.sourceDevice
            history = state.history; lastSyncedAt = state.lastSyncedAt
            isHistorySyncing = state.isHistorySyncing; hasNativeReviewWait = state.hasNativeReviewWait
        }
    }

    let store: StoreOf<ChatFeature>
    let connectionState: ConnectionState
    let onSidebarTap: (() -> Void)?
    let onFileBrowserTap: (() -> Void)?
    let onSettingsTap: (() -> Void)?
    let executionAccessMode: ExecutionAccessMode
    let onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)?
    let isTerminalPresented: Bool
    let onTerminalToggle: (() -> Void)?
    let onOpenFileReference: ((String) -> Void)?
    let onPinTap: (() -> Void)?
    let isPinned: Bool
    let onInboxTap: (() -> Void)?
    let onOverviewTap: (() -> Void)?
    let showsComposer: Bool
    private let renderPipeline: MessageRenderPipeline
    private let codeSyntaxHighlighter: CodeSyntaxHighlighter

    public init(
        store: StoreOf<ChatFeature>,
        connectionState: ConnectionState = .disconnected,
        onSidebarTap: (() -> Void)? = nil,
        onFileBrowserTap: (() -> Void)? = nil,
        onSettingsTap: (() -> Void)? = nil,
        executionAccessMode: ExecutionAccessMode = .defaultPermissions,
        onExecutionAccessModeChanged: ((ExecutionAccessMode) -> Void)? = nil,
        isTerminalPresented: Bool = false,
        onTerminalToggle: (() -> Void)? = nil,
        onOpenFileReference: ((String) -> Void)? = nil,
        onPinTap: (() -> Void)? = nil,
        isPinned: Bool = false,
        onInboxTap: (() -> Void)? = nil,
        onOverviewTap: (() -> Void)? = nil,
        showsComposer: Bool = true,
        renderPipeline: MessageRenderPipeline = .live,
        codeSyntaxHighlighter: CodeSyntaxHighlighter = CodexCodeSyntaxHighlighter()
    ) {
        self.store = store
        self.connectionState = connectionState
        self.onSidebarTap = onSidebarTap
        self.onFileBrowserTap = onFileBrowserTap
        self.onSettingsTap = onSettingsTap
        self.executionAccessMode = executionAccessMode
        self.onExecutionAccessModeChanged = onExecutionAccessModeChanged
        self.isTerminalPresented = isTerminalPresented
        self.onTerminalToggle = onTerminalToggle
        self.onOpenFileReference = onOpenFileReference
        self.onPinTap = onPinTap
        self.isPinned = isPinned
        self.onInboxTap = onInboxTap
        self.onOverviewTap = onOverviewTap
        self.showsComposer = showsComposer
        self.renderPipeline = renderPipeline
        self.codeSyntaxHighlighter = codeSyntaxHighlighter
    }

    public var body: some View {
        WithViewStore(store, observe: ViewState.init) { viewStore in
            VStack(spacing: 0) {
                header(viewStore: viewStore)
                if viewStore.hasUnconfirmedReply && !viewStore.isSending {
                    VStack(alignment: .leading, spacing: 4) {
                        CodexNotice(title: "上次发送结果未确认", detail: "原文已保留，不会自动重发。", symbol: "questionmark.circle", tone: .warning)
                        Button("我已核对原任务，继续编辑") { viewStore.send(.acknowledgeUnknownReply) }
                            .font(.footnote.weight(.medium)).frame(minHeight: 44)
                    }.padding(.horizontal, 16)
                }
                if viewStore.hasCachedSource, viewStore.history?.hasMore == true {
                    Button {
                        viewStore.send(.appDidBecomeActive)
                    } label: {
                        Label("继续读取已保存历史（\(viewStore.history?.messages.count ?? 0)/\(viewStore.history?.availableMessageCount ?? 0)）", systemImage: "text.badge.plus")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain)
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
                            colorScheme: colorScheme,
                            onOpenFileReference: onOpenFileReference
                        )
                    },
                    inputViewBuilder: { text, _, _, _, action, _ in
                        Group {
                          if showsComposer && viewStore.activeThreadId != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .bottom, spacing: 8) {
                                Menu {
                                    Button("浏览文件", systemImage: "folder") { onFileBrowserTap?() }
                                        .disabled(onFileBrowserTap == nil)
                                    Button("终端", systemImage: "terminal") { onTerminalToggle?() }
                                        .disabled(onTerminalToggle == nil)
                                } label: {
                                    Image(systemName: "square.grid.2x2").frame(width: 44, height: 44)
                                }
                                .disabled(onFileBrowserTap == nil && onTerminalToggle == nil)
                                .accessibilityLabel("文件与终端工具")
                                TextField(viewStore.canInput ? "继续这个任务…" : "记录回复草稿…", text: text, axis: .vertical)
                                    .font(.body).lineLimit(1...6).padding(.vertical, 11)
                                    .disabled(!viewStore.canEdit)
                                    .accessibilityIdentifier("task-composer")
                                    .onAppear { text.wrappedValue = viewStore.inputText }
                                    .onChange(of: viewStore.inputText) { _, value in
                                        if text.wrappedValue != value { text.wrappedValue = value }
                                    }
                                    .onChange(of: viewStore.isSending) { _, sending in
                                        if !sending { text.wrappedValue = viewStore.inputText }
                                    }
                                    .onChange(of: text.wrappedValue) { _, value in
                                        if let id = viewStore.activeThreadId { viewStore.send(.composerChanged(threadId: id, text: value)) }
                                    }
                                if viewStore.canInput {
                                  Button { action(.send) } label: {
                                    Group {
                                        if viewStore.isSending { ProgressView().tint(CodexAppearance.canvas) }
                                        else { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                                    }
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(CodexAppearance.canvas)
                                    .background(Color.primary, in: Circle())
                                    .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(viewStore.isSending ? "正在发送回复" : "发送回复")
                                .disabled(viewStore.isSending || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                } else {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("仅草稿")
                                        Text("不可发送")
                                    }
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .padding(.trailing, 8).padding(.bottom, 6)
                                        .fixedSize(horizontal: true, vertical: true)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("仅可记录回复草稿，当前来源暂不支持发送")
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .background(CodexAppearance.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(CodexAppearance.separator, lineWidth: 0.5))
                            if !viewStore.canInput {
                                Text("当前来源暂不支持发送。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

                          }
                        }
                    }
                )
                .showDateHeaders(viewStore.messages.allSatisfy { $0.createdAt > Date(timeIntervalSince1970: 0) })
                .showMessageTimeView(false)
                // 关闭 ExyteChat 的长按整段菜单，优先使用系统文本选择（支持按词/按段复制）。
                .showMessageMenuOnLongPress(false)
                .keyboardDismissMode(.onDrag)
                .setAvailableInputs((viewStore.canEdit && !isTerminalPresented) ? [.text] : [])
                .id(viewStore.identity ?? "no-thread")
                .overlay(alignment: .center) {
                    if viewStore.activeThreadId == nil {
                        emptyStateOverlay
                    }
                }
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
                    ),
                    images: ChatTheme.Images(
                        read: Image(systemName: "checkmark.circle.fill"),
                        delivered: Image(systemName: "checkmark.circle"),
                        sent: Image(systemName: "checkmark")
                    )
                )
                .background(ConversationViewportAlignment())
            }
            .background(pageBackgroundColor)
            .onAppear {
                renderPipeline.clearCache()
                viewStore.send(.onAppear)
            }
            .onDisappear { viewStore.send(.onDisappear) }
            .sheet(isPresented: $showIdentity) {
                NavigationStack {
                    Form {
                        Section("当前任务") { Text(viewStore.activeThreadTitle).textSelection(.enabled) }
                        Section("完整身份") { Text(viewStore.identity ?? "未选择任务").font(.footnote.monospaced()).textSelection(.enabled) }
                        if let device = viewStore.sourceDevice {
                            Section("来源设备") { Text(device).textSelection(.enabled) }
                        }
                        Section("阅读范围") {
                            Text("已显示 \(viewStore.messages.count) 条消息")
                            if let body = viewStore.history {
                                Text("来源本地共 \(body.availableMessageCount) 条；按来源顺序显示")
                                let missingTimes = viewStore.messages.filter { $0.createdAt <= Date(timeIntervalSince1970: 0) }.count
                                if missingTimes > 0 {
                                    Text("其中 \(missingTimes) 条消息未提供发送时间。观察时间不代表发送时间。")
                                }
                                if body.refreshRequested { Text("已请求来源刷新；当前仍显示上次可读历史。") }
                                if !body.attachments.isEmpty {
                                    ForEach(body.attachments) { item in
                                        Label(item.filename + " · " + item.availability, systemImage: "paperclip")
                                            .font(.footnote)
                                    }
                                }
                            }
                            if let first = viewStore.messages.first, first.createdAt > Date(timeIntervalSince1970: 0) {
                                Text("此页最早：" + MobileTime.timestamp(first.createdAt))
                            }
                            if let date = viewStore.lastSyncedAt { Text("上次同步观察：" + MobileTime.timestamp(date)) }
                            else { Text("本地记录，尚未完成同步") }
                        }
                    }
                    .navigationTitle("任务信息").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("完成") { showIdentity = false } }
                }
            }
            .sheet(isPresented: $showActivities) {
                NavigationStack {
                    List(viewStore.history?.records ?? []) { item in
                        DisclosureGroup(item.title) {
                            Text(item.id).font(.caption.monospaced()).textSelection(.enabled)
                            if let observed = item.observedAt { Text("来源观察于 " + observed).font(.caption) }
                            Text("此记录索引未提供执行正文或结果；请在原任务核对。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("来源记录").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showActivities = false } } }
                }
            }
        }
    }

    private var pageBackgroundColor: Color {
        Color(uiColor: .systemBackground)
    }

    private var chatMainBackgroundColor: Color {
        Color(uiColor: .systemBackground)
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
    private var emptyStateOverlay: some View {
        CodexEmptyState(title: "继续已有的工作", detail: "从任务列表打开一项工作，查看内容、进展和需要你处理的事项。", actionTitle: "打开任务列表", action: { onSidebarTap?() })
    }

    @ViewBuilder
    private func header(viewStore: ViewStore<ViewState, ChatFeature.Action>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Button { onSidebarTap?() } label: {
                    Image(systemName: "sidebar.leading")
                }.buttonStyle(CodexIconButtonStyle()).accessibilityLabel("打开任务列表")
                Button { showIdentity = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewStore.activeThreadId == nil ? "OpenCodex" : viewStore.activeThreadTitle)
                            .font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                            .multilineTextAlignment(.leading).foregroundStyle(.primary)
                        if viewStore.activeThreadId != nil {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if isPinned { Image(systemName: "pin.fill") }
                                sourceAndSyncStatus(viewStore)
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("任务信息：" + viewStore.activeThreadTitle)
                    .accessibilityValue(viewStore.activeThreadId == nil ? "" : (isPinned ? "已持续展示。" : "") + sourceAndSyncSummary(viewStore))
                    .accessibilityHint("查看完整标题、来源和阅读范围")
                Menu {
                    Button("目标总览", systemImage: "chart.bar.xaxis") { onOverviewTap?() }
                    Button("待你处理", systemImage: "tray") { onInboxTap?() }
                    if viewStore.activeThreadId != nil {
                        Button(isPinned ? "取消持续展示" : "持续展示此任务", systemImage: isPinned ? "pin.slash" : "pin") { onPinTap?() }
                        Button("来源记录（\(viewStore.history?.records.count ?? 0)）", systemImage: "list.bullet.rectangle") { showActivities = true }
                        Button("刷新来源历史", systemImage: "arrow.clockwise") { viewStore.send(.refreshHistory) }.disabled(viewStore.isHistorySyncing)
                        Button("浏览文件", systemImage: "folder") { onFileBrowserTap?() }
                            .disabled(onFileBrowserTap == nil)
                        Button("终端", systemImage: "terminal") { onTerminalToggle?() }
                            .disabled(onTerminalToggle == nil)
                    }
                    Button("连接与设置", systemImage: "network") { onSettingsTap?() }
                } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(CodexIconButtonStyle()).accessibilityLabel("任务更多选项")
            }
            if viewStore.activeThreadId != nil {
                if viewStore.history?.refreshRequested == true {
                    Text("已请求来源刷新，当前内容尚未更新")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)
                }
            }
            if viewStore.hasNativeReviewWait {
                Button { onInboxTap?() } label: {
                    Label("查看需要你处理的请求", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.font(.subheadline.weight(.medium)).tint(.orange).padding(.horizontal, 12)
            }
            if let error = viewStore.errorMessage {
                DisclosureGroup {
                    Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                } label: {
                    Label("同步或操作未完成 · 查看原因", systemImage: "exclamationmark.circle")
                        .font(.footnote.weight(.medium)).foregroundStyle(.red).frame(minHeight: 44)
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .background(CodexAppearance.canvas)
    }

    private func taskStatus(_ state: ViewStore<ViewState, ChatFeature.Action>) -> String {
        state.hasNativeReviewWait ? "有请求待处理" : "任务对话"
    }

    private func sourceAndSyncSummary(_ state: ViewStore<ViewState, ChatFeature.Action>) -> String {
        let parts = sourceAndSyncParts(state)
        return ([parts.source] + parts.sync).joined(separator: " · ")
    }

    private func sourceAndSyncStatus(_ state: ViewStore<ViewState, ChatFeature.Action>) -> some View {
        let parts = sourceAndSyncParts(state)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(parts.source).fixedSize()
                Text("·")
                Text(parts.sync.joined(separator: " · ")).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.source).fixedSize()
                Text(parts.sync.joined(separator: " · ")).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.source)
                ForEach(Array(parts.sync.enumerated()), id: \.offset) { _, fact in
                    Text(fact)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceAndSyncParts(_ state: ViewStore<ViewState, ChatFeature.Action>) -> (source: String, sync: [String]) {
        let source = state.hasCachedSource
            ? (state.history?.isPartial == true ? "部分已保存历史" : "上次可读历史")
            : taskStatus(state)
        let sync: [String]
        if state.isHistorySyncing { sync = ["正在同步"] }
        else if let date = state.lastSyncedAt {
            sync = state.errorMessage == nil ? ["上次同步 " + MobileTime.ago(date)] : ["同步失败", "上次 " + MobileTime.ago(date)]
        } else { sync = ["本地内容", "尚未同步"] }
        return (source, sync)
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
    let onOpenFileReference: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.user.isCurrentUser {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 4) {
                    messageIdentity
                    Text(message.text)
                        .textSelection(.enabled)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .fixedSize(horizontal: false, vertical: true)

                    if let style = statusStyle(message.status) {
                        Image(systemName: style.icon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(style.tint)
                    }
                }
            } else {
                let rendered = renderPipeline.render(message.text)
                VStack(alignment: .leading, spacing: 0) {
                    messageIdentity.padding(.horizontal, 12).padding(.bottom, 2)
                    Markdown(rendered.markdownContent)
                        .markdownTheme(messageTheme)
                        .relativeLineSpacing(.em(0.25))
                        .tint(markdownLinkColor)
                        .markdownCodeSyntaxHighlighter(codeSyntaxHighlighter)
                        .environment(\.openURL, OpenURLAction { url in
                            if let ref = parseCodexFileReference(from: url) {
                                onOpenFileReference?(ref)
                                return .handled
                            }
                            if url.scheme == nil {
                                let rawReference = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                                if rawReference.contains("/") || rawReference.contains(":") {
                                    onOpenFileReference?(rawReference)
                                    return .handled
                                }
                            }
                            switch url.scheme?.lowercased() {
                            case "http", "https":
                                return .systemAction(url)
                            default:
                                return .discarded
                            }
                        })
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)


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
        .padding(.vertical, 10)
    }

    private var messageIdentity: some View {
        HStack(spacing: 6) {
            Text(message.user.isCurrentUser ? "你" : message.user.name)
            if message.createdAt > Date(timeIntervalSince1970: 0) {
                Text(MobileTime.timestamp(message.createdAt))
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var messageTheme: Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                // MarkdownUI applies Dynamic Type to this unscaled baseline.
                FontSize(17)
                BackgroundColor(nil)
            }
            .link {
                ForegroundColor(markdownLinkColor)
                UnderlineStyle(.single)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(assistantInnerCodeColor)
            }
            .heading1 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.3)) }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.18)) }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .heading3 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.06)) }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .paragraph { configuration in configuration.label.markdownMargin(top: 0, bottom: 12) }
            .codeBlock { configuration in
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
            .table { configuration in
                            ScrollView(.horizontal) {
                                configuration.label
                                .fixedSize(horizontal: true, vertical: false)
                                .markdownTableBorderStyle(.init(color: assistantBorderColor))
                                .markdownTableBackgroundStyle(
                                    .alternatingRows(assistantTableEvenRowColor, assistantTableOddRowColor)
                                )
                            }.markdownMargin(top: 0, bottom: 12)
                        }
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

    private var markdownLinkColor: Color {
        Color(uiColor: .link)
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

    private func parseCodexFileReference(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "codexfs" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "ref" })?.value
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

    private var iconName: String {
        switch state {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting, .reconnecting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .failed, .disconnected:
            return "xmark.circle.fill"
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
            Image(systemName: iconName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
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
