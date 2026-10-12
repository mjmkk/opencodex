import SwiftUI

struct GoalOverviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [GoalOverviewRow] = []
    @State private var hasSnapshot = false
    @State private var isRefreshing = false
    @State private var failure: String?
    @State private var accountScope: String?
    @State private var snapshot: JSONValue?
    @State private var generation = UUID()

    var body: some View {
        GoalOverviewView(rows: rows, hasSnapshot: hasSnapshot, isRefreshing: isRefreshing,
            failure: failure, refresh: refresh)
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            .onDisappear { generation = UUID() }
    }

    @MainActor private func refresh() async {
        let request = UUID()
        generation = request
        isRefreshing = true
        defer { if generation == request { isRefreshing = false } }
        do {
            let scope = try MobileSyncEngine.scope()
            if accountScope != scope {
                rows = []; snapshot = nil; hasSnapshot = false; failure = nil; accountScope = scope
                if let entry = try? await MobileSyncCache.shared?.goalOverview(scope: scope) {
                    guard generation == request, (try? MobileSyncEngine.scope()) == scope else { return }
                    if (try? validate(entry.payload, scope: scope)) != nil,
                       let restored = try? GoalOverviewDecoder.rows(entry.payload, cached: true) {
                        rows = restored; snapshot = entry.payload; hasSnapshot = true
                    }
                }
            }
            let payload = try await APIClient.live.goalOverview()
            guard generation == request, (try? MobileSyncEngine.scope()) == scope else { return }
            try validate(payload, scope: scope)
            let updated = try GoalOverviewDecoder.rows(payload)
            // Advance the in-memory version before suspension so a concurrent
            // refresh cannot validate against the older page during persistence.
            snapshot = payload; rows = updated; hasSnapshot = true
            try await MobileSyncCache.shared?.saveGoalOverview(.init(payload: payload, receivedAt: Date()), scope: scope)
            guard generation == request, (try? MobileSyncEngine.scope()) == scope else { return }
            snapshot = payload; rows = updated; hasSnapshot = true; failure = nil
        } catch {
            guard generation == request else { return }
            let expectedNamespace = accountScope.flatMap { UserDefaults.standard.string(forKey: "codex.mirror.namespace." + $0) }
            if accountScope != (try? MobileSyncEngine.scope()) ||
                (snapshot != nil && snapshot?.objectValue?["namespace"]?.stringValue != expectedNamespace) {
                rows = []; snapshot = nil; hasSnapshot = false; accountScope = nil
            }
            if let snapshot, let restored = try? GoalOverviewDecoder.rows(snapshot, cached: true) { rows = restored }
            failure = hasSnapshot ? "读取失败，保留上次观察；判断时间未更新。" : "目标观察暂不可用，请稍后刷新。"
        }
    }

    private func validate(_ payload: JSONValue, scope: String) throws {
        guard let root = payload.objectValue,
              let namespace = root["namespace"]?.stringValue,
              let revision = root["snapshot_revision"]?.intValue else { throw CodexError.invalidState }
        // The existing authenticated Mirror sync establishes the source account.
        guard let expected = UserDefaults.standard.string(forKey: "codex.mirror.namespace." + scope),
              expected == namespace else { throw CodexError.invalidState }
        if let old = snapshot?.objectValue {
            guard old["namespace"]?.stringValue == namespace,
                  let previous = old["snapshot_revision"]?.intValue,
                  revision >= previous else { throw CodexError.invalidState }
        }
    }
}
