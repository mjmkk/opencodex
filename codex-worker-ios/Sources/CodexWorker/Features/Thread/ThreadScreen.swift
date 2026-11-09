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
    @State private var draft = ""
    @State private var sending = false
    @State private var sendNotice: String?
    @State private var pendingId: String?
    /// 刚从手机发出、服务端记录里还没出现的消息
    @State private var outgoing: [Transcript.Row] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
                }
                if let transcript {
                    if transcript.hasMore {
                        // Mirror 分页同步有断点：再拉一次会从上次停下的地方接着往前拉，不重复下载
                        Button { Task { await load() } } label: {
                            Text(loading ? "正在加载…" : "加载更早的消息")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain).disabled(loading)
                    }
                    ForEach(transcript.rows) { row in rowView(row) }
                    // 记录里已经出现同样文字的就不再单独显示
                    ForEach(outgoing.filter { o in !transcript.rows.suffix(6).contains { $0.kind == o.kind } }) { row in
                        rowView(row).opacity(0.7)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    ContentUnavailableView("没有可显示的对话", systemImage: "text.bubble")
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
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
                // 原生请求列表里没有这条线程的请求时，用 Node 观测到的“在等什么”兜底
                if requests.isEmpty, let w = member.waiting {
                    WaitingCard(waiting: w, hostLabel: HarnessMember.hostLabel(member.host) ?? "原机器")
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
            async let r: Void = loadRequests()
            await load(); await r
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
            if let sendNotice {
                Text(sendNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("回复 " + member.roleLabel, text: $draft, axis: .vertical)
                    .font(.body).lineLimit(1...6)
                    .padding(.vertical, 15)
                    .disabled(sending)
                Button { Task { await send() } } label: {
                    Group {
                        if sending { ProgressView().tint(Theme.page) }
                        else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)) }
                    }
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

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Codex：走 AGT-12 原有的原生控制通道。先读当前观测（拿 receipt 和 version），再发文字；
    /// 服务端写之前先落持久意图，同一个 submission_id 不会发第二次。返回值映射成和 harness/send 一样的状态
    @MainActor private func sendNative(_ text: String, submissionId: String) async throws -> String {
        let api = APIClient.live
        // 上次结果不明时先查回执，不重新发
        if let prior = try? await api.nativeSubmission(member.id, submissionId),
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

    @MainActor private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        Haptics.light()
        sending = true; sendNotice = nil
        defer { sending = false }
        // 同一条消息只生成一次 id：网络失败后重点发送，服务端会认出是同一条，不会投两次
        let cmid = pendingId ?? ("m" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        pendingId = cmid
        do {
            let status = member.kind == "codex" || member.kind == "unknown"
                ? try await sendNative(text, submissionId: cmid)
                : (try await APIClient.live.harnessSend(member.id, text, cmid)).objectValue?["status"]?.stringValue ?? ""
            switch status {
            case "queued", "received", "duplicate":
                outgoing.append(.init(id: cmid, kind: .user(text), at: Date()))
                draft = ""; pendingId = nil
                sendNotice = status == "received" ? "已送达" : "已送达，等对方处理"
                Task { try? await Task.sleep(for: .seconds(6)); await load() }
            case "unconfirmed":
                // 可能已经发出去了：保留 id，不清空输入框，但提示别急着重发
                outgoing.append(.init(id: cmid, kind: .user(text), at: Date()))
                draft = ""; pendingId = nil
                sendNotice = "已发出，还没收到确认；稍后刷新看看，不用重发"
            case "offline":
                sendNotice = member.kind == "claude" ? "对方会话现在没在运行，没有发出"
                    : "这个线程现在没在 Desktop 里打开，没有发出"
                pendingId = nil
            case "busy":
                sendNotice = "对方现在不接受输入（可能在等审批），没有发出"; pendingId = nil
            case "unsupported":
                sendNotice = "这台机器上的线程还不能从手机回复（" + (HarnessMember.hostLabel(member.host) ?? "未知机器") + "）"
                pendingId = nil
            default:
                sendNotice = "没有发出，可以再试一次"
            }
        } catch {
            sendNotice = "网络有问题，没确认是否发出；再点一次发送是安全的，不会重复"
        }
    }

    // MARK: - 加载

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        // 被取消（页面关闭或成员信息变化）时不显示错误，交给下一次加载
        defer { if Task.isCancelled { notice = nil } }
        defer { loading = false }
        do {
            if member.kind == "claude" {
                transcript = try TranscriptBuilder.claude(try await APIClient.live.harnessThread(member.id))
            } else if member.kind == "unknown",
                      let claude = try? TranscriptBuilder.claude(try await APIClient.live.harnessThread(member.id)) {
                // 不知道种类时先问服务端：是 Claude 会话就直接用，否则（409）继续走 Mirror
                transcript = claude
            } else {
                let thread = try await ThreadLookup.thread(member.id)
                if let cached = try await ThreadSyncClient.liveValue.cachedHistory(thread), !cached.messages.isEmpty {
                    transcript = TranscriptBuilder.codex(cached)
                }
                // Mirror 只自动同步最近活跃的线程；不在里面的线程，第一次请求会让 Mirror 排队去 Codex 拉，
                // 通常一分钟内拉到。拉到之前每 5 秒问一次，最多 2 分钟
                for attempt in 0..<24 {
                    let history = try await ThreadSyncClient.liveValue.syncHistory(thread, true)
                    // 服务端把“已排队”标在 thread 上而不是顶层，客户端拿不到可靠信号；正文为空就当还没拉到
                    if !history.messages.isEmpty {
                        transcript = TranscriptBuilder.codex(history); break
                    }
                    if transcript == nil { notice = "正在从 Codex 拉取这条线程，第一次大约需要一分钟" }
                    if attempt == 23 { notice = "Codex 还没返回内容，下拉重试" }
                    try await Task.sleep(for: .seconds(5))
                }
            }
            notice = nil
        } catch {
            notice = transcript == nil ? "暂时读不到这条线程，下拉重试" : "刷新失败，显示的是上次的内容"
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
        let cached = try await ThreadSyncClient.liveValue.cached()
        if let hit = cached.threads.first(where: { $0.threadId == nativeId }) { return hit }
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
