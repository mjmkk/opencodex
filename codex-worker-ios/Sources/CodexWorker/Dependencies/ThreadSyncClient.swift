import ComposableArchitecture
import CryptoKit
import Foundation

public struct MobileSyncResult: Equatable, Sendable {
    public var threads: [Thread]
    public var metadata: [String: ThreadSyncMetadata]
    public var changedThreadIds: [String]
    public var failures: [String: String]
    public var selectedThreadId: String? = nil
}

/// Repository boundary: business features see Thread history, never storage wire pages.
public struct ThreadSyncClient: DependencyKey, Sendable {
    public var cached: @Sendable () async throws -> MobileSyncResult
    public var cachedHistory: @Sendable (Thread) async throws -> ThreadHistory?
    public var syncHistory: @Sendable (Thread, Bool) async throws -> ThreadHistory
    public var sync: @Sendable ([String], Bool) async throws -> MobileSyncResult
    public var markRead: @Sendable (String) async throws -> Void
    public var setPinned: @Sendable (String, Bool) async throws -> Void
    public var selectThread: @Sendable (String?) async throws -> Void
    public static let liveValue: ThreadSyncClient = ThreadSyncClient(
        cached: { try await MobileSyncEngine.shared.cached() },
        cachedHistory: { thread in
            try await MobileSyncCache.shared?.mirrorBody(thread.threadId, scope: MobileSyncEngine.threadScope(for: thread))?.history
        },
        syncHistory: { thread, refresh in
            @Dependency(\.apiClient) var api
            guard let namespace = thread.origin?.namespace else { throw CodexError.invalidState }
            _ = try await MobileSyncEngine.shared.syncMirrorThread(thread.threadId, namespace: namespace, offline: !refresh, api: api)
            guard let cached = try await MobileSyncCache.shared?.mirrorBody(thread.threadId, scope: MobileSyncEngine.threadScope(for: thread)) else { throw CodexError.invalidState }
            return cached.history
        },
        sync: { ids, background in
            @Dependency(\.apiClient) var api
            return try await MobileSyncEngine.shared.sync(preferred: ids, background: background, api: api)
        },
        markRead: { try await MobileSyncCache.shared?.markRead($0, scope: MobileSyncEngine.threadScope()) },
        setPinned: { try await MobileSyncCache.shared?.setPinned($1, threadId: $0, scope: MobileSyncEngine.threadScope()) },
        selectThread: { try await MobileSyncCache.shared?.selectThread($0, scope: MobileSyncEngine.threadScope()) }
    )
    public static let testValue: ThreadSyncClient = liveValue
}
extension DependencyValues {
    public var threadSyncClient: ThreadSyncClient {
        get { self[ThreadSyncClient.self] }
        set { self[ThreadSyncClient.self] = newValue }
    }
}
actor MobileSyncEngine {
    static let shared = MobileSyncEngine()
    static func scope() throws -> String {
        guard let configuration = WorkerConfiguration.load() else { throw CodexError.notConfigured }
        return SHA256.hash(data: Data((configuration.baseURL + "\n" + (configuration.token ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func threadScope(for thread: Thread) throws -> String { try threadScope(namespace: thread.origin?.namespace) }
    static func threadScope(namespace: String? = nil) throws -> String {
        let scope = try scope()
        guard let namespace = namespace ?? UserDefaults.standard.string(forKey: "codex.mirror.namespace." + scope) else { return scope + ":no-current-source" }
        return scope + ":mirror:" + namespace
    }
    private func cache() throws -> MobileSyncCache {
        guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }; return cache
    }
    func cached() async throws -> MobileSyncResult {
        let scope = try Self.threadScope(); let cache = try cache()
        return try await .init(threads: cache.threads(scope: scope), metadata: cache.metadata(scope: scope),
            changedThreadIds: [], failures: [:], selectedThreadId: cache.selectedThread(scope: scope))
    }
    func syncMirrorThread(_ id: String, namespace: String, offline: Bool = true,
                          api: APIClient, maxPages: Int = 20) async throws -> MirrorBody {
        let account = try Self.scope(); let scope = try Self.threadScope(namespace: namespace)
        let cache = try cache()
        return try await MirrorHistoryReader.sync(id, namespace: namespace, scope: scope, cache: cache,
            offline: offline, maxPages: maxPages,
            validateAccount: { guard try Self.scope() == account else { throw CancellationError() } },
            readPage: { try await api.mirrorBody(id, $0, $1, $2) })
    }

    func sync(preferred: [String], background: Bool, api: APIClient) async throws -> MobileSyncResult {
        let account = try Self.scope(); let cache = try cache()
        let index = try await api.mirrorIndex()
        guard try Self.scope() == account else { throw CancellationError() }
        guard index.ok, index.source == "local_mirror", !index.namespace.isEmpty,
              index.threads.allSatisfy({ $0.namespace == nil || $0.namespace == index.namespace }) else { throw CodexError.invalidState }
        let scope = try Self.threadScope(namespace: index.namespace)
        try await cache.saveMirrorIndex(index, scope: scope)
        UserDefaults.standard.set(index.namespace, forKey: "codex.mirror.namespace." + account)
        let metadata = try await cache.metadata(scope: scope)
        let ordered = index.threads.sorted {
            let left = preferred.contains($0.thread_id) || metadata[$0.thread_id]?.pinned == true
            let right = preferred.contains($1.thread_id) || metadata[$1.thread_id]?.pinned == true
            return left != right ? left : ($0.last_seen_at ?? "") > ($1.last_seen_at ?? "")
        }
        var changed: [String] = []; var failures: [String: String] = [:]
        if index.possibly_truncated == true { failures["mirror-index"] = "当前目录可能未包含全部任务；已缓存任务仍保留" }
        for thread in ordered.prefix(background ? 2 : 5) {
            try Task.checkCancellation()
            do {
                let before = try await cache.mirrorBody(thread.thread_id, scope: scope)?.body
                let body = try await syncMirrorThread(thread.thread_id, namespace: index.namespace, api: api, maxPages: background ? 2 : 4)
                if body.page.snapshot != before?.page.snapshot || body.messages.count != before?.messages.count { changed.append(thread.thread_id) }
            } catch is CancellationError { throw CancellationError() }
            catch { failures[thread.thread_id] = error.localizedDescription }
        }
        guard try Self.scope() == account else { throw CancellationError() }
        return try await .init(threads: cache.threads(scope: scope), metadata: cache.metadata(scope: scope),
            changedThreadIds: changed, failures: failures, selectedThreadId: cache.selectedThread(scope: scope))
    }
}
