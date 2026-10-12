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
        self.renderPipeline = renderPipeline
        self.codeSyntaxHighlighter = codeSyntaxHighlighter
    }

    public var body: some View {
        WithViewStore(store, observe: ViewState.init) { viewStore in
            VStack(spacing: 0) {
                header(viewStore: viewStore)
                if viewStore.hasCachedSource {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "internaldrive")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewStore.history?.isPartial == false ? "上次可读历史" : "部分历史已保存").font(.caption.weight(.medium))
                            Text(viewStore.history?.refreshRequested == true ? "已请求来源刷新；当前显示上次可读历史" : "上次可读历史 · 可先保存回复草稿")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let body = viewStore.history, body.hasMore {
                                Button("继续读取已缓存历史（\(body.messages.count)/\(body.availableMessageCount)）") { viewStore.send(.appDidBecomeActive) }
                                    .font(.caption)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 16).padding(.vertical, 6)
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
                        HStack(alignment: .bottom, spacing: 8) {
                            Menu {
                                Button("浏览文件", systemImage: "folder") { onFileBrowserTap?() }
                                Button("终端", systemImage: "terminal") { onTerminalToggle?() }
                            } label: {
                                Image(systemName: "plus").frame(width: 44, height: 44)
                            }.accessibilityLabel("添加工具")
                            TextField("继续这个任务…", text: text, axis: .vertical)
                                .lineLimit(1...5).padding(.vertical, 12)
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
                            Button { action(.send) } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30)).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("发送回复")
                            .disabled(!viewStore.canInput || viewStore.isSending || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                        .padding(.horizontal, 16).padding(.vertical, 8)
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
                    )
                )
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
                        Section("身份") { Text(viewStore.activeThreadId ?? "未选择任务").font(.footnote.monospaced()).textSelection(.enabled) }
                        if let device = viewStore.sourceDevice {
                            Section("来源设备") { Text(device).textSelection(.enabled) }
                        }
                        Section("阅读范围") {
                            Text("已显示 \(viewStore.messages.count) 条消息")
                            if let body = viewStore.history {
                                Text("来源本地共 \(body.availableMessageCount) 条；按来源顺序显示")
                                Text("来源未提供消息发送时间，观察时间不代表发送时间。")
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
                    .navigationTitle("任务信息")
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
                    .navigationTitle("来源记录")
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
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("选择线程后即可开始对话")
                .font(.headline)
            Text("从任务列表打开已有工作，继续查看或回复。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开线程列表") {
                onSidebarTap?()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func header(viewStore: ViewStore<ViewState, ChatFeature.Action>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { onSidebarTap?() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel("打开线程列表")
                Button { showIdentity = true } label: {
                    Text(viewStore.activeThreadTitle).font(.headline).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
                }.accessibilityLabel("任务信息：" + viewStore.activeThreadTitle)
                Menu {
                    Button("Goal Overview", systemImage: "chart.bar.xaxis") { onOverviewTap?() }
                    Button("待你处理", systemImage: "tray") { onInboxTap?() }
                    if viewStore.activeThreadId != nil {
                        Button(isPinned ? "取消持续展示" : "Pin 持续展示", systemImage: isPinned ? "pin.slash" : "pin") { onPinTap?() }
                        Button("来源记录（\(viewStore.history?.records.count ?? 0)）", systemImage: "list.bullet.rectangle") { showActivities = true }
                        Button("刷新来源历史", systemImage: "arrow.clockwise") { viewStore.send(.refreshHistory) }.disabled(viewStore.isHistorySyncing)
                        Button("浏览文件", systemImage: "folder") { onFileBrowserTap?() }
                        Button("终端", systemImage: "terminal") { onTerminalToggle?() }
                    }
                    Button("连接", systemImage: "network") { onSettingsTap?() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("任务更多选项")
            }
            if viewStore.activeThreadId != nil {
                HStack(spacing: 5) {
                    if isPinned { Image(systemName: "pin.fill").accessibilityLabel("已持续展示") }
                    Text(taskStatus(viewStore))
                    if viewStore.isHistorySyncing { Text("· 正在同步") }
                    else if let date = viewStore.lastSyncedAt {
                        Text(viewStore.errorMessage == nil ? "· 上次同步 " + MobileTime.ago(date) : "· 同步失败，上次 " + MobileTime.timestamp(date))
                    }
                    else { Text("· 本地内容") }
                }.font(.caption).foregroundStyle(.secondary).padding(.leading, 52)
            }
            if viewStore.hasNativeReviewWait {
                Button { onInboxTap?() } label: {
                    Label("查看需要你处理的请求", systemImage: "hand.raised")
                }.font(.footnote).tint(.orange).padding(.horizontal, 12).padding(.top, 6)
            }
            if viewStore.hasUnconfirmedReply && !viewStore.isSending {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上次发送结果未确认，原文已保留，不会自动重发。")
                    Button("我已核对原任务，继续编辑") { viewStore.send(.acknowledgeUnknownReply) }
                }.font(.footnote).padding(.horizontal, 12)
            }
            if let error = viewStore.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(3).padding(.horizontal, 12)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private func taskStatus(_ state: ViewStore<ViewState, ChatFeature.Action>) -> String {
        state.hasNativeReviewWait ? "有请求待处理" : "任务对话"
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
                        .font(.body)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)

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
            Text(message.createdAt > Date(timeIntervalSince1970: 0) ? MobileTime.timestamp(message.createdAt) : "原文未提供时间")
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var userBubbleMaxWidth: CGFloat {
#if canImport(UIKit)
        let width = UIScreen.main.bounds.width
        return min(max(width * 0.74, 240), 460)
#else
        return 320
#endif
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
