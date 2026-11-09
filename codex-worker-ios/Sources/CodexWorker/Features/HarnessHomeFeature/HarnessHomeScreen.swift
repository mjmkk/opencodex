import SwiftUI

/// AGT-26 S6：根页面。负责拉取 `/v1/harness/tree` 和刷新。
/// 打开时先显示上次缓存的 Goal 树，再去拉新数据（参考 Happy 的 offline-first）；拉取失败时保留旧数据，只给一行说明。
struct HarnessHomeScreen: View {
    @Binding var goals: [HarnessGoal]
    let openThread: (HarnessMember) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isRefreshing = false
    @State private var failure: String?

    var body: some View {
        HarnessHomeView(goals: goals, isRefreshing: isRefreshing, failure: failure,
                        refresh: refresh, openThread: openThread)
            .task {
                if goals.isEmpty, let cached = HarnessTreeCache.load() { goals = cached }
                await refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
    }

    @MainActor private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let payload = try await APIClient.live.harnessTree()
            goals = try HarnessTreeDecoder.goals(payload)
            HarnessTreeCache.save(payload)
            failure = nil
        } catch {
            failure = goals.isEmpty ? "暂时拿不到 Goal 列表，下拉重试。" : "正在重连，显示的是上一次的结果。"
        }
    }
}

/// Goal 树的本地缓存：只保存最近一次成功响应的原始 JSON，打开 App 时先显示它。按服务地址分开存放。
enum HarnessTreeCache {
    private static var key: String? {
        guard let c = WorkerConfiguration.load() else { return nil }
        return "agt.harness.tree." + c.baseURL
    }
    static func load() -> [HarnessGoal]? {
        guard let key, let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return try? HarnessTreeDecoder.goals(payload)
    }
    static func save(_ payload: JSONValue) {
        guard let key, let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
