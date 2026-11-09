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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
                }
                if let transcript {
                    if transcript.hasMore {
                        Text("更早的消息暂未加载").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(transcript.rows) { row in rowView(row) }
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
        .safeAreaInset(edge: .bottom) { composer }
        // 成员信息变了（例如深链打开后 Goal 树才到，kind 从 unknown 变成 claude）就重新加载；
        // .task(id:) 会取消上一次加载，所以 loading 不会卡住
        .task(id: member.id + "|" + member.kind) { loading = false; await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
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
            // 长消息默认只显示 6 行，点一下展开（参考 Happy 对长 prompt 的处理），免得一条消息占满整屏
            let open = expandedFolds.contains(row.id)
            HStack {
                Spacer(minLength: 48)
                Text(text).font(.body)
                    .lineLimit(open ? nil : 6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
                    .onTapGesture { toggleFold(row.id) }
            }
        case .assistant(let text):
            Markdown(text)
                .markdownTextStyle { FontSize(16) }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .folded(let count, _):
            Label("中间过程 \(count) 步", systemImage: "ellipsis.rectangle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }

    // MARK: - 输入框（发送接口还没有，先显示原因，不假装可用）

    private var composer: some View {
        HStack(spacing: 10) {
            Text("回复功能还没接上：服务端暂无发送接口")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
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

    private func toggleFold(_ id: String) {
        if expandedFolds.contains(id) { expandedFolds.remove(id) } else { expandedFolds.insert(id) }
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
