import MarkdownUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// AGT-26 S6：线程页。Codex 和 Claude 共用这一个页面。
/// 页面上只有对话，中间过程折叠成一行。列表从底部开始，用户停在底部时自动跟随新消息（参考 Happy 的 ChatViewController）。
/// 打开时先显示缓存，再去拉最新内容；拉取失败时保留已显示的内容，并在顶部给一行说明。
struct ThreadScreen: View {
    let member: HarnessMember
    let goal: HarnessGoal?

    @Environment(\.scenePhase) private var scenePhase
    @State private var transcript: Transcript?
    @State private var loading = false
    @State private var notice: String?
    @State private var expandedFolds: Set<String> = []
    @State private var requests: [NativeRemoteRequest] = []
    @State private var outbox: ChatOutbox
    private var outgoing: [ChatOutbox.Message] { outbox.messages }
    @State private var followingBottom = true
    @State private var viewportHeight: CGFloat = 0

    init(member: HarnessMember, goal: HarnessGoal?) {
        self.member = member
        self.goal = goal
        _outbox = State(initialValue: ChatOutbox.thread(member.id))
    }
    /// 本机会话文件里读到的最近几十行；Mirror 每次刷新后都叠在它上面，Mirror 落后时也不会把新回复盖掉
    @State private var live: [Transcript.Row] = []
    /// 只渲染最后这么多行；往上翻时先放出本地已有的，用完了再去服务端拉更早的
    @State private var shownRows = 80
    @State private var loadingEarlier = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
                }
                if let transcript {
                    if transcript.rows.count > shownRows || transcript.hasMore {
                        Button { Task { await showEarlier() } } label: {
                            Text(loadingEarlier ? "正在加载…" : "加载更早的消息")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain).disabled(loadingEarlier)
                    }
                    ForEach(transcript.rows.suffix(shownRows)) { row in rowView(row) }
                } else if loading, outgoing.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if outgoing.isEmpty {
                    ContentUnavailableView("没有可显示的对话", systemImage: "text.bubble")
                        .padding(.top, 60)
                }
                ForEach(outgoing.filter { o in
                    o.matchedID.map { matched in !(transcript?.rows.contains { $0.id == matched } ?? false) } ?? true
                }) { o in outgoingView(o) }
                if let error = outbox.storageError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Color.clear.frame(height: 1).id("bottom")
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ChatBottomKey.self, value: geo.frame(in: .named("chat-scroll")).maxY)
                    })
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .coordinateSpace(name: "chat-scroll")
        .background(GeometryReader { geo in Color.clear.onAppear { viewportHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, height in viewportHeight = height } })
        .onPreferenceChange(ChatBottomKey.self) { bottom in followingBottom = bottom <= viewportHeight + 100 }
        .onChange(of: outgoing.count) { _, _ in
            followingBottom = true
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .onChange(of: viewportHeight) { oldHeight, height in
            if height < oldHeight, followingBottom { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .onChange(of: transcript) { _, value in
            if let value { outbox.remember(value) }
            if followingBottom { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .overlay(alignment: .bottomTrailing) {
            // 只在有未展示的更早消息时显示"跳到最新"按钮
            if !followingBottom {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { shownRows = max(shownRows, transcript?.rows.count ?? 0) }
                    // 下一帧再滚到底
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.ink)
                        .background(Theme.page.clipShape(Circle()))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 100)
                .transition(.scale.combined(with: .opacity))
            }
        }
        } // ScrollViewReader
        .navigationTitle(member.title ?? member.runtimeLine)
        .navigationBarTitleDisplayMode(.inline)
        // 导航栏用不透明材质，避免滚动内容透到标题下面
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                // 原生请求列表里没有这条线程的请求时，用 Node 观测到的"在等什么"兜底
                if requests.isEmpty, let w = member.waiting {
                    WaitingCard(waiting: w, hostLabel: HarnessMember.hostLabel(member.host) ?? "原机器", isClaude: member.kind == "claude")
                        .padding(.horizontal, 12)
                }
                // 等你处理的请求贴在输入框上方，不混进对话流
                ForEach(requests) { r in
                    InlineRequestCard(item: r, hostLabel: HarnessMember.hostLabel(member.host) ?? "原机器") {
                        Task { await loadRequests() }
                    }
                    .padding(.horizontal, 12)
                }
                composer
            }
        }
        // 成员信息变了（例如深链打开后 Goal 树才到，kind 从 unknown 变成 claude）就重新加载；
        // .task(id:) 会取消上一次加载，所以 loading 不会卡住
        .task(id: member.id + "|" + member.kind) {
            loading = false
            shownRows = 80
            if let cached = outbox.cached { transcript = cached }
#if DEBUG
            if let auto = UserDefaults.standard.string(forKey: "AGTAutoSend"), !auto.isEmpty,
               member.kind != "unknown", outbox.draft.isEmpty, outgoing.isEmpty {
                outbox.draft = auto
                send()
            }
#endif
            await load()
            await loadRequests()
            // 只在当前页面持续读取；切页会取消，回到前台仍继续。真实本机读取不占云端历史额度。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                guard scenePhase == .active else { continue }
                if member.kind == "claude" {
                    await backgroundRefresh()
                } else if let t = await liveTranscript() {
                    transcript = t; notice = nil
                }
            }
        }
        .refreshable { async let r: Void = loadRequests(); await load(); await r }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadRequests(); await load() } }
        }
    }

    // MARK: - 标题和菜单

    private var header: some View {
        VStack(spacing: 1) {
            // 没有标题时用 Goal 名和角色，例如「AGT-26 · Worker」
            Text(member.title ?? [goal?.id, member.roleLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(member.roleLabel + " · " + member.runtimeLine + (transcript?.model.map { " · " + $0 } ?? ""))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var menu: some View {
        Menu {
            Button { copy(member.id) } label: { Label("复制原生 id", systemImage: "doc.on.doc") }
            if let url = goal?.issueURL {
                Link(destination: url) { Label("在 Linear 打开 " + (goal?.id ?? ""), systemImage: "arrow.up.right.square") }
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    // MARK: - 行

    @ViewBuilder
    private func rowView(_ row: Transcript.Row) -> some View {
        switch row.kind {
        case .user(let text):
            // 浅灰气泡、正文色文字、靠右（ChatGPT / Claude）。长消息默认 6 行，点一下展开
            let open = expandedFolds.contains(row.id)
            HStack {
                Spacer(minLength: 64)
                Text(text).font(.body)
                    .lineLimit(open ? nil : 6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onTapGesture { toggleFold(row.id) }
            }
            .padding(.top, 10)
        case .assistant(let text):
            // 全宽、无气泡、无头像（ChatGPT / Claude / Happy 都这么做）
            Markdown(text)
                .markdownTextStyle { FontSize(17) }
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .folded(let steps, let seconds):
            // 一行纯灰字 + ›，不加框（ChatGPT「Thought for Ns ›」/ Happy「Worked for 2m3s ›」）；点开逐条显示
            let open = expandedFolds.contains(row.id)
            VStack(alignment: .leading, spacing: 8) {
                Button { toggleFold(row.id) } label: {
                    HStack(spacing: 4) {
                        Text(TranscriptBuilder.foldLabel(steps: steps.count, seconds: seconds))
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.subheadline).foregroundStyle(.tertiary)
                    .frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                            Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(8)
                        }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                }
            }
        }
    }

    // MARK: - 输入框（发送接口还没有，先显示原因，不假装可用）

    /// 悬浮胶囊输入框（ChatGPT 52 高、距两侧 16；Happy 圆角 30 外壳），内容从它下面滚过。
    /// 发送走 /v1/harness/send：服务端按线程跑在哪选通道。发出去的消息先以「发送中」挂在列表底部，
    /// 投递确认后显示「已送达」，等下一次刷新拿到真实记录后自然被替换
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("回复 " + member.roleLabel, text: $outbox.draft, axis: .vertical)
                    .font(.body).lineLimit(1...6)
                    .padding(.vertical, 15)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.page)
                    .frame(width: 36, height: 36)
                    .background(Theme.ink.opacity(canSend ? 1 : 0.25), in: Circle())
                }
                .disabled(!canSend)
                .padding(.bottom, 8)
                .accessibilityLabel("发送")
            }
            .padding(.leading, 18).padding(.trailing, 8)
            .frame(minHeight: 52)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var canSend: Bool { !outbox.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Codex：走 AGT-12 原有的原生控制通道。先读当前观测（拿 receipt 和 version），再发文字；
    /// 服务端写之前先落持久意图，同一个 submission_id 不会发第二次。返回值映射成和 harness/send 一样的状态
    @MainActor private func sendNative(_ text: String, submissionId: String, isRetry: Bool) async throws -> String {
        let api = APIClient.live
        // 重试时先查回执，不重新发；第一次发不用查，省一次往返
        if isRetry, let prior = try? await api.nativeSubmission(member.id, submissionId),
           let st = prior.objectValue?["status"]?.stringValue {
            return st == "accepted" ? "queued" : st == "rejected" ? "failed" : "unconfirmed"
        }
        let control: JSONValue
        do { control = try await api.nativeControl(member.id) }
        catch CodexError.apiError(let code, _) {
            // 线程不在名单里，或者现在没被 Desktop 加载：都没有可写的原生通道
            if code == "NATIVE_THREAD_NOT_CONFIGURED" { return "unsupported" }
            if code == "NATIVE_OWNER_UNAVAILABLE" { return "offline" }
            throw CodexError.apiError(code: code, message: "")
        }
        guard let c = control.objectValue, c["input_available"] == .bool(true),
              let receipt = c["control_receipt"]?.stringValue, let version = c["control_version"]?.stringValue
        else { return "busy" }
        let r = try await api.nativeInput(member.id, text, submissionId, receipt, version)
        switch r.objectValue?["status"]?.stringValue {
        case "accepted": return "queued"
        case "rejected": return "failed"
        default: return "unconfirmed"
        }
    }

    @ViewBuilder
    private func outgoingView(_ o: ChatOutbox.Message) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Spacer(minLength: 40)
                switch o.state {
                case .pending: ProgressView().controlSize(.small)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        .accessibilityLabel("没有发出，点按重发")
                case .sent: EmptyView()
                case .unconfirmed: Image(systemName: "clock").foregroundStyle(.secondary)
                }
                Text(o.text).font(.body).lineLimit(6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            if o.state == .unconfirmed {
                Text("发送结果待确认").font(.footnote).foregroundStyle(.secondary)
            }
            if case .failed(let why) = o.state {
                Text(why).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.top, 10)
        .contentShape(Rectangle())
        .onTapGesture { if case .failed = o.state { retry(o.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("outgoing-" + o.id)
    }

    /// 先持久保存，再让后台按顺序投递；输入不等待网络。
    @MainActor private func send() {
        let text = outbox.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, outbox.enqueue(text, rows: transcript?.rows ?? []) else { return }
        Haptics.light()
        outbox.draft = ""
        Task { await drain() }
    }

    @MainActor private func retry(_ id: String) {
        guard let i = outbox.messages.firstIndex(where: { $0.id == id }) else { return }
        Haptics.light()
        outbox.messages[i].state = .pending
        outbox.save()
        Task { await drain() }
    }

    @MainActor private func drain() async {
        guard !outbox.draining else { return }
        outbox.draining = true
        defer { outbox.draining = false }
        while let i = outbox.messages.firstIndex(where: { $0.state == .pending }) {
            let o = outbox.messages[i]
            outbox.messages[i].tried = true
            guard outbox.save() else { break }
            let result = await deliver(o.text, id: o.id, isRetry: o.tried)
            guard let j = outbox.messages.firstIndex(where: { $0.id == o.id }) else { continue }
            // 收到真实消息记录的确认，优先于随后返回的网络错误。
            if outbox.messages[j].matchedID == nil { outbox.messages[j].state = result }
            outbox.save()
        }
    }

    /// 投递一条；未知送达独立显示，不能把它当成已送达
    @MainActor private func deliver(_ text: String, id cmid: String, isRetry: Bool) async -> ChatOutbox.Message.State {
        guard outbox.usesCurrentConnection else { return .failed("连接设置已改变，请回原连接后重试") }
        do {
            let useHarness = outgoing.first { $0.id == cmid }?.route == .harness
            var status = !useHarness && (member.kind == "codex" || member.kind == "unknown")
                ? try await sendNative(text, submissionId: cmid, isRetry: isRetry) : "unsupported"
            // 原生通道只覆盖 spirit-master 上的 Codex 线程；其他机器上的 Codex 和 Claude 走 harness/send
            // （服务端按 Registry 选 Mac queue / Claude inbox）。原生通道已明确没写（unsupported）才换，不会两边都发。
            // offline 只在读 control 时出现（线程没被 Desktop 加载），此时还没写出任何东西；
            // harness/send 会用 send_message_to_thread 把线程拉起再投递，所以也换过去
            if status == "unsupported" || (status == "offline" && member.kind != "claude") {
                guard outbox.usesCurrentConnection else { return .failed("连接设置已改变，请回原连接后重试") }
                if let i = outbox.messages.firstIndex(where: { $0.id == cmid }) {
                    outbox.messages[i].route = .harness
                    guard outbox.save() else { return .failed("消息未保存，请检查可用空间") }
                }
                status = (try await APIClient.live.harnessSend(member.id, text, cmid)).objectValue?["status"]?.stringValue ?? ""
            }
            switch status {
            case "queued", "received": return .sent
            // duplicate 只证明旧 id 已被占用，不证明旧请求已真正投递；等实际记录确认。
            case "duplicate", "unconfirmed": return .unconfirmed
            case "offline": return .failed(member.kind == "claude" ? "对方会话没在运行" : "线程没在 Desktop 里打开")
            case "busy": return .failed("对方正在等待处理，请稍后重试")
            case "unsupported": return .failed("这台机器暂时不支持手机回复")
            default: return .failed("暂时无法发送，请稍后重试")
            }
        } catch {
            if case CodexError.unauthorized = error { return .failed("连接凭据已失效，请检查连接设置") }
            if case CodexError.timeout = error { return .failed("发送超时，请点按重试") }
            return .failed("连接失败，请检查网络后点按重试")
        }
    }

    // MARK: - 加载
    // 策略：有缓存 → 立刻显示，关 loading，后台静默刷新（不再显示 spinner）。
    // 没缓存 → 显示 spinner，拉到第一条内容就关掉，之后仍后台刷新。
    // 刷新失败只在顶部写一行小字，不替换已有内容。

    @MainActor private func load() async {
        guard !loading else { return }
        // 1. 先把缓存内容立刻渲染给用户（和微信/飞书的做法一样）。读缓存期间显示转圈，不闪“没有可显示的对话”
        if transcript == nil || transcript?.rows.isEmpty == true {
            loading = true
            await showCached()
            loading = false
        }
        // 有缓存时不显示 spinner，直接后台刷新
        // （仍在 .task 里 await，页面关掉时会一起取消）
        if transcript != nil && transcript?.rows.isEmpty == false {
            await backgroundRefresh()
            return
        }
        // 没缓存：显示 spinner，等第一次网络结果
        loading = true
        defer { loading = false }
        await backgroundRefresh()
    }

    /// 只读本地 SQLite，不走网络。失败静默
    @MainActor private func showCached() async {
        do {
            if member.kind == "claude" || member.kind == "unknown",
               let json = await ClaudeTranscriptCache.load(member.id), let t = try? TranscriptBuilder.claude(json) {
                transcript = t; return
            }
            if member.kind == "claude" { return }
            // unknown 也试一下 Mirror 缓存：只查本地，查不到 ThreadLookup 会抛错，静默跳过
            if member.kind == "unknown" {
                let known = try? await MobileSyncCache.shared?.thread(member.id, scope: MobileSyncEngine.threadScope())
                if known == nil { return }
            }
            // 只用本地路径：先查单条 SQLite 缓存，拿到 namespace 就直接构造 Thread，不走 mirrorIndex 网络请求
            let scope = try MobileSyncEngine.threadScope()
            if let t = try await MobileSyncCache.shared?.thread(member.id, scope: scope) {
                if let cached = try await ThreadSyncClient.liveValue.cachedHistory(t), !cached.messages.isEmpty {
                    transcript = TranscriptBuilder.merge(TranscriptBuilder.codex(cached), live: live)
                }
            } else if let ns = UserDefaults.standard.string(forKey: "codex.mirror.namespace." + (try MobileSyncEngine.scope())) {
                let t2 = MirrorThread(thread_id: member.id, namespace: ns).thread(in: ns)
                if let cached = try await ThreadSyncClient.liveValue.cachedHistory(t2), !cached.messages.isEmpty {
                    transcript = TranscriptBuilder.merge(TranscriptBuilder.codex(cached), live: live)
                }
            }
        } catch {}
    }

    /// 读一次 /v1/harness/live，把结果叠到当前记录上。只对 Codex 线程；服务端不支持这台机器或读失败时返回 nil。
    /// 返回值的 isPartial 为 true 表示手上还没有更早的历史，需要再去 Mirror 补。
    @MainActor private func liveTranscript() async -> Transcript? {
        guard member.kind == "codex" || member.kind == "unknown",
              let root = try? await APIClient.live.harnessLive(member.id).objectValue,
              root["ok"] == .bool(true), let items = root["messages"]?.arrayValue else { return nil }
        let messages = items.enumerated().compactMap { i, v -> ThreadHistory.Message? in
            guard let o = v.objectValue, let text = o["text"]?.stringValue else { return nil }
            let id = o["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "live-\(i)-\(o["at"]?.stringValue ?? "")"
            return .init(id: id, role: o["role"]?.stringValue, text: text,
                         sentAt: o["at"]?.stringValue.flatMap(TranscriptBuilder.parseDate))
        }
        live = TranscriptBuilder.codex(ThreadHistory(threadIdentity: member.id, messages: messages, records: [],
            attachments: [], downloadedAt: Date(), isPartial: false, hasMore: false,
            availableMessageCount: messages.count, refreshRequested: false)).rows
        guard let base = transcript, !base.rows.isEmpty else {
            return Transcript(rows: live, model: nil, isPartial: true, hasMore: true)
        }
        return TranscriptBuilder.merge(base, live: live)
    }

    /// 走一次网络刷新，不阻塞 UI。第一次见到这条线程时最多等 2 分钟（后台轮询）。
    @MainActor private func backgroundRefresh() async {
        do {
            if member.kind == "claude" {
                let json = try await APIClient.live.harnessThread(member.id)
                transcript = try TranscriptBuilder.claude(json); notice = nil
                await ClaudeTranscriptCache.save(member.id, json); return
            }
            if member.kind == "unknown", let json = try? await APIClient.live.harnessThread(member.id),
               let claude = try? TranscriptBuilder.claude(json) {
                transcript = claude; notice = nil
                await ClaudeTranscriptCache.save(member.id, json); return
            }
            // 先读本机会话文件：不占云端额度、几秒内就是最新的。读不到再走下面的 Mirror
            if let t = await liveTranscript() {
                transcript = t; notice = nil
                if !t.isPartial { return }
            }
            let thread = try await ThreadLookup.thread(member.id)
            // Mirror 只自动同步最近活跃的线程；没拉过的线程第一次需要最多约 1 分钟。
            // 有缓存时只轮询 3 次（15 秒）就放弃，让用户下拉触发；
            // 完全没内容时最多轮询 24 次（2 分钟）。
            let hasContent = transcript != nil && transcript?.rows.isEmpty == false
            let maxAttempts = hasContent ? 3 : 24
            for attempt in 0..<maxAttempts {
                try Task.checkCancellation()
                let history = try await ThreadSyncClient.liveValue.syncHistory(thread, true)
                if !history.messages.isEmpty {
                    transcript = TranscriptBuilder.merge(TranscriptBuilder.codex(history), live: live); notice = nil; return
                }
                if !hasContent {
                    notice = "正在从 Codex 拉取这条线程，第一次大约需要一分钟"
                }
                if attempt == maxAttempts - 1 { notice = "Codex 还没返回内容，下拉重试" }
                try await Task.sleep(for: .seconds(5))
            }
        } catch is CancellationError {
            notice = nil
        } catch {
            if transcript == nil || transcript?.rows.isEmpty == true {
                notice = "暂时读不到这条线程，下拉重试"
            } else {
                notice = "刷新失败，显示的是上次的内容"
            }
        }
    }

    /// 先放出本地已经有、还没渲染的行；本地用完了再去服务端往前拉一段
    @MainActor private func showEarlier() async {
        guard let transcript, !loadingEarlier else { return }
        Haptics.light()
        if transcript.rows.count > shownRows { shownRows += 80; return }
        guard member.kind != "claude" else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let thread = try await ThreadLookup.thread(member.id)
            if let history = try await ThreadSyncClient.liveValue.loadEarlier(thread) {
                let next = TranscriptBuilder.codex(history)
                shownRows += max(0, next.rows.count - transcript.rows.count)
                self.transcript = TranscriptBuilder.merge(next, live: live)
            }
        } catch {
            notice = "更早的消息暂时拉不到，稍后再试"
        }
    }

    /// 只取这条线程上还没结束的原生请求。服务端读不到（比如原机器离线）时就不显示卡片，不影响看对话
    @MainActor private func loadRequests() async {
#if DEBUG
        // 模拟器验收用：-AGTSampleRequest YES 时放一张示例卡片（不会发送：response_available 为 false）
        if UserDefaults.standard.bool(forKey: "AGTSampleRequest") {
            requests = [NativeRemoteRequest(receipt_id: "sample", request_id: .string("1"), thread_id: member.id,
                request: ["method": .string("item/commandExecution/requestApproval"),
                          "params": .object(["command": .string("cmake --build build -j8 && ctest --output-on-failure")])],
                response_available: false, response_submitted: false)]
            return
        }
#endif
        guard member.kind != "claude" else { return }
        guard let list = try? await APIClient.live.nativeRequests() else { return }
        requests = list.data.filter { $0.thread_id == member.id && $0.native_resolution == nil && $0.native_terminal == nil }
    }

    private func toggleFold(_ id: String) {
        Haptics.light()
        withAnimation(.snappy(duration: 0.2)) {
            if expandedFolds.contains(id) { expandedFolds.remove(id) } else { expandedFolds.insert(id) }
        }
    }

    private func copy(_ id: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = id
#endif
    }
}

/// 用原生 id 在本机已同步的线程列表里找对应的 Thread（Mirror 的 key 是 namespace:thread_id）
enum ThreadLookup {
    /// 先查本地缓存的 Mirror 目录；目录里没有（Mirror 还没同步过它）就按当前 namespace 直接构造，
    /// 由正文请求触发 Mirror 去拉。namespace 不知道时拉一次目录拿到它
    static func thread(_ nativeId: String) async throws -> Thread {
        if let hit = try? await MobileSyncCache.shared?.thread(nativeId, scope: MobileSyncEngine.threadScope()) { return hit }
        let key = "codex.mirror.namespace." + (try MobileSyncEngine.scope())
        var namespace = UserDefaults.standard.string(forKey: key)
        if namespace == nil {
            let synced = try await ThreadSyncClient.liveValue.sync([nativeId], true)
            if let hit = synced.threads.first(where: { $0.threadId == nativeId }) { return hit }
            namespace = UserDefaults.standard.string(forKey: key)
        }
        guard let namespace else { throw CodexError.invalidState }
        return MirrorThread(thread_id: nativeId, namespace: namespace).thread(in: namespace)
    }
}

/// Claude 会话正文的本地缓存：打开时先显示上次的内容，再去服务端拉最新的。放在 Caches 目录，系统清了也只是第一次慢一点
enum ClaudeTranscriptCache {
    private static func url(_ id: String) -> URL? {
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("claude-transcripts", isDirectory: true).appendingPathComponent(safe + ".json")
    }
    static func load(_ id: String) async -> JSONValue? {
        guard let url = url(id) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }.value
    }
    static func save(_ id: String, _ json: JSONValue) async {
        guard let url = url(id) else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(json).write(to: url, options: .atomic)
        }.value
    }
}

private struct ChatBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
