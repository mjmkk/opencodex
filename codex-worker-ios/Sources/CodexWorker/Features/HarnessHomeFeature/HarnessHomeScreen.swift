import SwiftUI

/// AGT-26 S6：首页容器，负责拉取 `/v1/harness/tree` 并处理刷新。
/// 失败时保留上一次成功的结果，并显示一行说明，不清空页面。
struct HarnessHomeScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var goals: [HarnessGoal] = []
    @State private var isRefreshing = false
    @State private var failure: String?
    let openThread: (HarnessMember) -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            HarnessHomeView(goals: goals, isRefreshing: isRefreshing, failure: failure,
                            refresh: refresh, openThread: openThread)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成", action: close)
                    }
                }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    @MainActor private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            goals = try HarnessTreeDecoder.goals(try await APIClient.live.harnessTree())
            failure = nil
        } catch {
            failure = goals.isEmpty ? "暂时拿不到 Goal 列表，下拉重试。" : "刷新失败，显示的是上一次的结果。"
        }
    }
}
