import Foundation

/// 用原生 id 在本机已同步的线程列表里找对应的 Thread（Mirror 的 key 是 namespace:thread_id）
enum ThreadLookup {
    /// 先查本地缓存的 Mirror 目录；目录里没有（Mirror 还没同步过它）就按当前 namespace 直接构造，
    /// 由正文请求触发 Mirror 去拉。namespace 不知道时拉一次目录拿到它
    static func thread(_ nativeId: String) async throws -> Thread {
        if let hit = try? await MobileSyncCache.shared?.thread(nativeId, scope: MobileSyncEngine.threadScope()) { return hit }
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
