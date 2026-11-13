import SwiftUI

/// AGT-26 S6：根页面。负责拉取 `/v1/harness/tree` 和刷新。
/// 打开时先显示上次缓存的 Goal 树，再去拉新数据（参考 Happy 的 offline-first）；拉取失败时保留旧数据，只给一行说明。
struct HarnessHomeScreen: View {
    @Binding var goals: [HarnessGoal]
    var currentId: String? = nil
    let openThread: (HarnessMember) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isRefreshing = false
    @State private var failure: String?
    @State private var observedAt = HarnessTreeCache.loadObservationTime()

    var body: some View {
        HarnessHomeView(goals: goals, observedAt: observedAt, currentId: currentId, isRefreshing: isRefreshing, failure: failure,
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
            let scope = try MobileSyncEngine.scope()
            let payload = try await APIClient.live.harnessTree()
            guard scope == (try? MobileSyncEngine.scope()), !Task.isCancelled else { return }
            guard HarnessTreeCache.isCurrent(payload) else { throw CodexError.invalidState }
            goals = try HarnessTreeDecoder.goals(payload)
            observedAt = HarnessTreeCache.observationTime(payload)
            HarnessTreeCache.save(payload)
            failure = nil
        } catch {
            failure = goals.isEmpty ? "暂时拿不到 Goal 列表，下拉重试。" : "正在重连，显示的是上一次的结果。"
        }
    }
}

/// 只保留新版 Goal 投影，按地址和凭证隔离，避免旧分组或其他账号的数据混入。
enum HarnessTreeCache {
    private static var key: String? {
        guard let scope = try? MobileSyncEngine.scope() else { return nil }
        return "agt.harness.tree.v2." + scope
    }
    static func isCurrent(_ payload: JSONValue) -> Bool {
        payload.objectValue?["schema_version"] == .int(2)
    }
    static func load() -> [HarnessGoal]? {
        guard let payload = loadPayload() else { return nil }
        return try? HarnessTreeDecoder.goals(payload)
    }
    private static func loadPayload() -> JSONValue? {
        guard let key, let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data), isCurrent(payload) else { return nil }
        return payload
    }
    static func loadObservationTime() -> Date? { loadPayload().flatMap(observationTime) }
    static func observationTime(_ payload: JSONValue) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (payload.objectValue?["goals"]?.arrayValue ?? []).compactMap { goal -> Date? in
            guard let raw = goal.objectValue?["topology_observed_at"]?.stringValue else { return nil }
            return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }.min()
    }
    static func save(_ payload: JSONValue) {
        guard isCurrent(payload), let key, let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
