import SwiftUI

struct GoalOverviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [GoalOverviewRow] = []
    @State private var inventoryValidation: GoalInventoryValidation = .unknown
    @State private var hasSnapshot = false
    @State private var isRefreshing = false
    @State private var failure: String?
    @State private var accountScope: String?
    @State private var sourceNamespace: String?
    @State private var snapshot: JSONValue?
    @State private var generation = UUID()

    var body: some View {
        GoalOverviewView(rows: rows, inventoryValidation: inventoryValidation, hasSnapshot: hasSnapshot, isRefreshing: isRefreshing,
            failure: failure, refresh: refresh)
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                identityChanged()
            }
            .onDisappear { generation = UUID(); isRefreshing = false }
    }

    @MainActor private func refresh() async {
        // Foreground and explicit refresh share one cache/version baseline.
        guard !isRefreshing else { return }
        let request = UUID()
        generation = request
        isRefreshing = true
        defer { if generation == request { isRefreshing = false } }
        do {
            let scope = try MobileSyncEngine.scope()
            let namespace = UserDefaults.standard.string(forKey: "codex.mirror.namespace." + scope)
            if accountScope != scope || sourceNamespace != namespace {
                clearSnapshot()
                accountScope = scope; sourceNamespace = namespace
            }
            guard let namespace, let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
            // Read the durable baseline on every refresh, including after an
            // earlier refresh was cancelled while reading it.
            await restoreCache(scope: scope, namespace: namespace, request: request)
            guard accepts(request, scope: scope, namespace: namespace) else { return }
            let payload = try await APIClient.live.goalOverview()
            guard accepts(request, scope: scope, namespace: namespace) else { return }
            try validate(payload, scope: scope, namespace: namespace)
            let updated = try GoalOverviewDecoder.rows(payload)
            let validation = try GoalOverviewDecoder.inventoryValidation(payload)
            // Do not publish a response until persistence accepts its version.
            try await cache.saveGoalOverview(.init(payload: payload, receivedAt: Date()), scope: scope)
            guard accepts(request, scope: scope, namespace: namespace) else { return }
            try validate(payload, scope: scope, namespace: namespace)
            snapshot = payload; rows = updated; inventoryValidation = validation; hasSnapshot = true; failure = nil
        } catch {
            guard generation == request else { return }
            if let scope = accountScope, let namespace = sourceNamespace {
                guard accepts(request, scope: scope, namespace: namespace) else { return }
                // A different view may have saved a newer page while this
                // request was suspended. Restore that page after a rejected write.
                await restoreCache(scope: scope, namespace: namespace, request: request)
                guard accepts(request, scope: scope, namespace: namespace) else { return }
            }
            if let snapshot, let restored = try? GoalOverviewDecoder.rows(snapshot, cached: true) { rows = restored }
            if let snapshot, let restored = try? GoalOverviewDecoder.inventoryValidation(snapshot, cached: true) {
                inventoryValidation = restored
            }
            failure = hasSnapshot ? "读取失败，保留上次观察；判断时间未更新。" : "目标观察暂不可用，请稍后刷新。"
        }
    }

    @MainActor private func restoreCache(scope: String, namespace: String, request: UUID) async {
        if let entry = try? await MobileSyncCache.shared?.goalOverview(scope: scope) {
            guard accepts(request, scope: scope, namespace: namespace) else { return }
            if (try? validate(entry.payload, scope: scope, namespace: namespace)) != nil,
               let restored = try? GoalOverviewDecoder.rows(entry.payload, cached: true),
               let validation = try? GoalOverviewDecoder.inventoryValidation(entry.payload, cached: true) {
                rows = restored; inventoryValidation = validation; snapshot = entry.payload; hasSnapshot = true
            }
        }
    }

    @MainActor private func accepts(_ request: UUID, scope: String, namespace: String) -> Bool {
        guard generation == request else { return false }
        guard (try? MobileSyncEngine.scope()) == scope,
              UserDefaults.standard.string(forKey: "codex.mirror.namespace." + scope) == namespace else {
            identityChanged()
            return false
        }
        return true
    }

    @MainActor private func identityChanged() {
        let scope = try? MobileSyncEngine.scope()
        let namespace = scope.flatMap { UserDefaults.standard.string(forKey: "codex.mirror.namespace." + $0) }
        guard accountScope != scope || sourceNamespace != namespace else { return }
        generation = UUID(); isRefreshing = false
        clearSnapshot(); accountScope = nil; sourceNamespace = nil
        Task { await refresh() }
    }

    private func clearSnapshot() {
        rows = []; inventoryValidation = .unknown; snapshot = nil; hasSnapshot = false; failure = nil
    }

    private func validate(_ payload: JSONValue, scope: String, namespace: String) throws {
        guard let root = payload.objectValue,
              root["namespace"]?.stringValue == namespace,
              let revision = root["snapshot_revision"]?.intValue,
              UserDefaults.standard.string(forKey: "codex.mirror.namespace." + scope) == namespace
        else { throw CodexError.invalidState }
        if let old = snapshot?.objectValue {
            guard old["namespace"]?.stringValue == namespace,
                  let previous = old["snapshot_revision"]?.intValue,
                  revision >= previous else { throw CodexError.invalidState }
        }
    }
}
