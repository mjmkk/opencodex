import SwiftUI

/// AGT-26 S6 原地重写后的根视图：启动后直接进入「工作」Goal 树，点任意成员进入它的线程页。
/// 旧的聊天主界面、抽屉、Goal Overview、Terminal、文件浏览、独立收件箱都已删除，只能在 git 历史里找到。
/// 推送和深链（opencodex://thread/<id>、opencodex://work）都在这里统一路由，同一个线程不会重复打开。
struct RootView: View {
    @State private var path: [Route] = []
    @State private var goals: [HarnessGoal] = []
    @State private var showSettings = !Self.isConfigured
    @State private var pendingOpen: String?

    enum Route: Hashable {
        case thread(memberId: String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            HarnessHomeScreen(goals: $goals, openThread: { open($0.id) })
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("连接设置")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .thread(let id):
                        // 每次渲染都重新解析：深链可能早于 Goal 树加载完成，树加载好之后这里会拿到真正的成员信息
                        let (member, goal) = lookup(id)
                        ThreadScreen(member: member, goal: goal)
                    }
                }
        }
        .sheet(isPresented: $showSettings) { ConnectionSettingsView { showSettings = false } }
        .onAppear {
            if let id = MobileLifecycle.takePendingThread() { pendingOpen = id }
            if let id = UserDefaults.standard.string(forKey: "AGTOpenThread") { pendingOpen = id }
        }
        // 深链和推送要等 Goal 树加载好再打开，这样线程页能拿到正确的 harness 和机器信息；
        // 树已经有缓存的话，第一帧就能打开
        .onChange(of: goals) { _, _ in
            if let id = pendingOpen, !goals.isEmpty { pendingOpen = nil; open(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: MobileLifecycle.openThreadNotification)) { note in
            if let id = note.object as? String {
                _ = MobileLifecycle.takePendingThread()
                if goals.isEmpty { pendingOpen = id } else { open(id) }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "opencodex" else { return }
            if url.host == "work" { path = [] }
            if url.host == "thread", url.pathComponents.count == 2 { open(url.lastPathComponent) }
        }
    }

    /// 同一个线程已经在最上层时不再压栈（推送重复到达时去重，参考 Happy 的 NotificationResponseFilter）
    private func open(_ id: String) {
        if case .thread(let top)? = path.last, top == id { return }
        path.append(.thread(memberId: id))
    }

    /// 在已加载的 Goal 树里找这个成员（包括子代理）；找不到时按 Codex 线程处理
    private func lookup(_ id: String) -> (HarnessMember, HarnessGoal?) {
        for g in goals {
            for m in g.members {
                if m.id == id { return (m, g) }
                if let s = m.subagents.first(where: { $0.id == id }) { return (s, g) }
            }
        }
        // 不在树里：kind 记为 unknown，由线程页先问服务端（Claude 会话），服务端回 409 再走 Mirror（Codex）。不按 id 长相去猜
        return (HarnessMember(id: id, role: .worker, kind: "unknown", host: nil, title: nil, model: nil), nil)
    }

    private static var isConfigured: Bool { WorkerConfiguration.load()?.token?.isEmpty == false }
}
