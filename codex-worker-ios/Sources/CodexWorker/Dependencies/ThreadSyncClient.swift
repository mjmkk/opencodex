import ComposableArchitecture
import CryptoKit
import Foundation

public struct MobileSyncResult: Equatable, Sendable {
    public var threads: [Thread]
    public var metadata: [String: ThreadSyncMetadata]
    public var changedThreadIds: [String]
    public var failures: [String: String]
}

public struct ThreadSyncClient: DependencyKey, Sendable {
    public var cached: @Sendable () async throws -> MobileSyncResult
    public var cachedEvents: @Sendable (String) async throws -> [EventEnvelope]
    public var sync: @Sendable (_ preferred: [String], _ background: Bool) async throws -> MobileSyncResult
    public var syncThread: @Sendable (String) async throws -> [EventEnvelope]
    public var markRead: @Sendable (String) async throws -> Void
    public var setPinned: @Sendable (String, Bool) async throws -> Void
    public var appendStream: @Sendable (String, [EventEnvelope]) async throws -> Void = { _, _ in }
    public var hints: @Sendable () -> AsyncThrowingStream<Void, Error> = { .init { $0.finish() } }

    public static let liveValue = ThreadSyncClient(
        cached: { try await MobileSyncEngine.shared.cached() },
        cachedEvents: { try await MobileSyncEngine.shared.cachedEvents($0) },
        sync: { ids, background in
            @Dependency(\.apiClient) var api
            let client = api
            if !background { return try await MobileSyncEngine.shared.sync(preferred: ids, background: false, api: api) }
            return try await withThrowingTaskGroup(of: MobileSyncResult.self) { group in
                group.addTask { try await MobileSyncEngine.shared.sync(preferred: ids, background: true, api: client) }
                group.addTask { try await Task.sleep(for: .seconds(20)); throw CancellationError() }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        },
        syncThread: { id in
            @Dependency(\.apiClient) var api
            return try await MobileSyncEngine.shared.syncThread(id, api: api)
        },
        markRead: { try await MobileSyncEngine.shared.markRead($0) },
        setPinned: { try await MobileSyncEngine.shared.setPinned($0, $1) },
        appendStream: { try await MobileSyncEngine.shared.appendStream($0, $1) },
        hints: { AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let configuration = WorkerConfiguration.load(),
                          let url = URL(string: configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/sync/stream") else { throw CodexError.notConfigured }
                    var request = URLRequest(url: url); request.timeoutInterval = 60
                    if let token = configuration.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CodexError.invalidState }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        try Task.checkCancellation(); continuation.yield(())
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        } }
    )
    public static let testValue = ThreadSyncClient(
        cached: { .init(threads: [], metadata: [:], changedThreadIds: [], failures: [:]) },
        cachedEvents: { _ in [] },
        sync: { _, _ in .init(threads: [], metadata: [:], changedThreadIds: [], failures: [:]) },
        syncThread: { _ in [] }, markRead: { _ in }, setPinned: { _, _ in })
}

extension DependencyValues {
    public var threadSyncClient: ThreadSyncClient {
        get { self[ThreadSyncClient.self] }
        set { self[ThreadSyncClient.self] = newValue }
    }
}

actor MobileSyncEngine {
    static let shared = MobileSyncEngine()
    private var inFlight: [String: Task<[EventEnvelope], Error>] = [:]

    static func scope() throws -> String {
        guard let configuration = WorkerConfiguration.load() else { throw CodexError.notConfigured }
        // Cache isolation across endpoints/accounts; the token itself is never persisted here.
        return SHA256.hash(data: Data((configuration.baseURL + "\n" + (configuration.token ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func cache() throws -> MobileSyncCache {
        guard let cache = MobileSyncCache.shared else { throw CodexError.invalidState }
        return cache
    }

    func cached() async throws -> MobileSyncResult {
        let scope = try Self.scope(); let cache = try cache()
        return try await .init(threads: cache.threads(scope: scope), metadata: cache.metadata(scope: scope),
            changedThreadIds: [], failures: [:])
    }

    func cachedEvents(_ id: String) async throws -> [EventEnvelope] {
        try await cache().events(id, scope: Self.scope())
    }

    func markRead(_ id: String) async throws { try await cache().markRead(id, scope: Self.scope()) }
    func setPinned(_ id: String, _ pinned: Bool) async throws { try await cache().setPinned(pinned, threadId: id, scope: Self.scope()) }
    func appendStream(_ id: String, _ events: [EventEnvelope]) async throws {
        try await cache().appendProvisional(events, threadId: id, scope: Self.scope())
    }

    func syncThread(_ id: String, api: APIClient, maxPages: Int = 20) async throws -> [EventEnvelope] {
        let scope = try Self.scope(); let cache = try cache(); let key = scope + ":" + id
        if let task = inFlight[key] {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        let task = Task<[EventEnvelope], Error> {
            var checkpoint = try await cache.checkpoint(id, scope: scope)
            var rebuilt = false
            for _ in 0..<maxPages {
                try Task.checkCancellation()
                guard try Self.scope() == scope else { throw CancellationError() }
                do {
                    let page = try await api.syncThreadEvents(id, checkpoint.cursor, checkpoint.generation, 200)
                    guard try Self.scope() == scope else { throw CancellationError() }
                    try await cache.merge(page, after: checkpoint, threadId: id, scope: scope)
                    if page.sourceConnected == false { throw CodexError.invalidState }
                    checkpoint = .init(cursor: page.nextCursor, generation: page.generation)
                    if !page.hasMore { return try await cache.events(id, scope: scope) }
                } catch let error as CodexError where error == .cursorExpired && !rebuilt {
                    rebuilt = true; checkpoint = SyncCheckpoint(replacingGeneration: checkpoint.generation)
                    // No resetThread: the old readable generation remains until rebuild commits.
                }
            }
            // The saved staging cursor resumes next time. Never label an incomplete fetch as current.
            return try await cache.events(id, scope: scope)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func sync(preferred: [String], background: Bool, api: APIClient) async throws -> MobileSyncResult {
        let scope = try Self.scope(); let cache = try cache()
        let response = try await api.listThreads(nil)
        guard try Self.scope() == scope else { throw CancellationError() }
        try await cache.saveThreads(response.data, scope: scope)
        if let approvals = try? await api.mobileApprovals() {
            guard try Self.scope() == scope else { throw CancellationError() }
            try await cache.saveApprovals(approvals.data, scope: scope)
        }
        let metadata = try await cache.metadata(scope: scope)
        let ordered = response.data.sorted {
            let left = preferred.contains($0.threadId) ? 0 : ($0.pendingApprovalCount > 0 ? 1 : ($0.executionState == "RUNNING" ? 2 : 3))
            let right = preferred.contains($1.threadId) ? 0 : ($1.pendingApprovalCount > 0 ? 1 : ($1.executionState == "RUNNING" ? 2 : 3))
            return left == right ? ($0.updatedAt ?? "") > ($1.updatedAt ?? "") : left < right
        }
        var changed: [String] = []; var failures: [String: String] = [:]
        for thread in ordered.prefix(background ? 3 : 8) {
            try Task.checkCancellation()
            do {
                _ = try await syncThread(thread.threadId, api: api, maxPages: background ? 2 : 4)
                let after = try await cache.metadata(scope: scope)[thread.threadId]
                if after?.latestCursor != metadata[thread.threadId]?.latestCursor ||
                    after?.generation != metadata[thread.threadId]?.generation { changed.append(thread.threadId) }
            } catch is CancellationError { throw CancellationError() }
            catch { failures[thread.threadId] = error.localizedDescription }
        }
        return try await .init(threads: cache.threads(scope: scope), metadata: cache.metadata(scope: scope),
            changedThreadIds: changed, failures: failures)
    }
}
