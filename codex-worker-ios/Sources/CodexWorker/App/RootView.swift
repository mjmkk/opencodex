import SwiftUI

/// AGT-26 S6 根视图，布局学 ChatGPT / Claude 手机端：主区域是当前线程，Goal 树放在左侧抽屉里。
/// - 从屏幕左缘右滑或点左上角按钮打开抽屉；拖过 35% 或甩得够快就打开，否则弹回
/// - 抽屉打开时主区域稍微缩小、加圆角和遮罩，点遮罩或左滑关闭
/// - 启动时回到上次打开的线程；推送和深链（opencodex://thread/<id>、opencodex://work）也在这里统一处理，打开的是同一个线程就不重复加载
struct RootView: View {
    // 启动时先用上次的 Goal 树：直接打开线程时马上知道它是 Codex 还是 Claude，可以立刻读对应的缓存
    @State private var goals: [HarnessGoal] = HarnessTreeCache.load() ?? []
    @State private var currentId: String? = UserDefaults.standard.string(forKey: "AGTOpenThread")
        ?? UserDefaults.standard.string(forKey: Self.lastThreadKey)
    @State private var drawerOpen = UserDefaults.standard.bool(forKey: "AGTDrawer")
    @State private var drag: CGFloat = 0
    @State private var showSettings = !Self.isConfigured

    private static let lastThreadKey = "agt.lastThread"

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.86, 380)
            let progress = drawerProgress(width)
            ZStack(alignment: .leading) {
                Theme.page.ignoresSafeArea()
                drawer.frame(width: width)
                    .offset(x: (progress - 1) * width * 0.3)
                    .opacity(progress == 0 ? 0 : 0.4 + 0.6 * progress)
                main
                    .clipShape(RoundedRectangle(cornerRadius: progress > 0 ? 20 * progress + 0.01 : 0, style: .continuous))
                    .overlay {
                        Color.black.opacity(0.18 * progress).ignoresSafeArea()
                            .allowsHitTesting(drawerOpen)
                            .onTapGesture { setDrawer(false) }
                    }
                    .scaleEffect(1 - 0.06 * progress)
                    .offset(x: progress * width)
                    .shadow(color: .black.opacity(0.12 * progress), radius: 16)
                    .ignoresSafeArea(edges: progress > 0 ? .vertical : [])
            }
            .gesture(drawerGesture(width))
        }
        .sheet(isPresented: $showSettings) { ConnectionSettingsView { showSettings = false } }
        .onAppear { if let id = MobileLifecycle.takePendingThread() { open(id) } }
        .onReceive(NotificationCenter.default.publisher(for: MobileLifecycle.openThreadNotification)) { note in
            if let id = note.object as? String { _ = MobileLifecycle.takePendingThread(); open(id) }
        }
        .onOpenURL { url in
            guard url.scheme == "opencodex" else { return }
            if url.host == "work" { setDrawer(true) }
            if url.host == "thread", url.pathComponents.count == 2 { open(url.lastPathComponent) }
        }
    }

    // MARK: - 抽屉：Goal 树

    private var drawer: some View {
        NavigationStack {
            HarnessHomeScreen(goals: $goals, currentId: currentId, openThread: { open($0.id) })
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("连接设置")
                    }
                }
        }
    }

    // MARK: - 主区域：当前线程

    private var main: some View {
        NavigationStack {
            Group {
                if let id = currentId {
                    let (member, goal) = lookup(id)
                    // 换线程时整页重建，不把上一个线程的内容和展开状态带过来
                    ThreadScreen(member: member, goal: goal).id(id)
                } else {
                    ContentUnavailableView("选一个线程", systemImage: "sidebar.left",
                        description: Text("从左侧打开 Goal 列表，点任意线程进入对话。"))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { setDrawer(true) } label: {
                        Image(systemName: "line.3.horizontal")
                            .overlay(alignment: .topTrailing) {
                                // 有 Goal 需要你处理时，菜单按钮上带一个橙点
                                if goals.contains(where: \.needsYou) {
                                    Circle().fill(Theme.needsYou).frame(width: 8, height: 8).offset(x: 4, y: -3)
                                }
                            }
                    }
                    .accessibilityLabel("打开 Goal 列表")
                }
            }
        }
        // 底色铺满安全区，否则抽屉关着时会从输入框下面露出来
        .background(Theme.page.ignoresSafeArea())
    }

    // MARK: - 手势和状态

    private func drawerProgress(_ width: CGFloat) -> CGFloat {
        let base: CGFloat = drawerOpen ? width : 0
        return min(max((base + drag) / width, 0), 1)
    }

    /// 关着时只认从左缘 24pt 内开始的右滑，免得和列表里的横滑操作冲突；开着时任意位置左滑都能关
    private func drawerGesture(_ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if drawerOpen { drag = min(0, v.translation.width) }
                else if v.startLocation.x < 24 { drag = max(0, v.translation.width) }
            }
            .onEnded { v in
                let moved = drag
                drag = 0
                guard moved != 0 else { return }
                let velocity = v.predictedEndTranslation.width - v.translation.width
                if drawerOpen { setDrawer(!(moved < -width * 0.35 || velocity < -250)) }
                else { setDrawer(moved > width * 0.35 || velocity > 250) }
            }
    }

    private func setDrawer(_ open: Bool) {
        if open != drawerOpen { Haptics.soft() }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { drawerOpen = open; drag = 0 }
    }

    private func open(_ id: String) {
        if currentId != id {
            currentId = id
            UserDefaults.standard.set(id, forKey: Self.lastThreadKey)
        }
        setDrawer(false)
    }

    /// 在 Goal 树里找这个成员（包括子代理）。树还没加载或不在树里时 kind 记为 unknown，
    /// 线程页会先问服务端是不是 Claude 会话，不是再走 Mirror。树加载好后这里会重新算，拿到正确的机器和模型
    private func lookup(_ id: String) -> (HarnessMember, HarnessGoal?) {
        for g in goals {
            for m in g.members {
                if m.id == id { return (m, g) }
                if let s = m.subagents.first(where: { $0.id == id }) { return (s, g) }
            }
        }
        return (HarnessMember(id: id, role: .worker, kind: "unknown", host: nil, title: nil, model: nil), nil)
    }

    private static var isConfigured: Bool { WorkerConfiguration.load()?.token?.isEmpty == false }
}
