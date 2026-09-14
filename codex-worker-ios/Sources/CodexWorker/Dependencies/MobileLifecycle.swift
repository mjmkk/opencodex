@preconcurrency import ActivityKit
@preconcurrency import BackgroundTasks
import CodexActivityModels
import Foundation
import OSLog

@MainActor
public enum MobileLifecycle {
    public static let openThreadNotification = Notification.Name("opencodex.openThread")
    public static let openApprovalsNotification = Notification.Name("opencodex.openApprovals")
    public static func openApprovals() {
        UserDefaults.standard.set(true, forKey: "opencodex.pendingApprovals")
        NotificationCenter.default.post(name: openApprovalsNotification, object: nil)
    }
    public static func takePendingApprovals() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: "opencodex.pendingApprovals") }
        return UserDefaults.standard.bool(forKey: "opencodex.pendingApprovals")
    }
    private static let pendingKey = "opencodex.pendingNotificationThread"
    private static let refreshID = "li.CodexWorkerApp.refresh"
    private static let logger = Logger(subsystem: "OpenCodex", category: "MobileSync")

    public static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            let work = Task { @MainActor in
                scheduleBackgroundRefresh()
                do {
                    let result = try await ThreadSyncClient.liveValue.sync([], true)
                    await updatePinned(result)
                    task.setTaskCompleted(success: true)
                } catch { task.setTaskCompleted(success: false) }
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    public static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.debug("Background refresh was not scheduled: \(error.localizedDescription, privacy: .public)") }
    }

    public static func openThread(_ id: String) {
        guard !id.isEmpty, id.count < 256 else { return }
        UserDefaults.standard.set(id, forKey: pendingKey)
        NotificationCenter.default.post(name: openThreadNotification, object: id)
    }
    public static func takePendingThread() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: pendingKey) }
        return UserDefaults.standard.string(forKey: pendingKey)
    }

    /// Only the explicit Pin button can create an activity. Sync may update or end one.
    public static func setPinned(_ pinned: Bool, thread: Thread) async throws {
        let scope = try MobileSyncEngine.scope()
        let existing = Activity<PinnedThreadAttributes>.activities.filter {
            $0.attributes.threadId == thread.threadId && $0.attributes.accountScope == scope
        }
        if !pinned {
            for activity in existing { await activity.end(nil, dismissalPolicy: .immediate) }
            try await ThreadSyncClient.liveValue.setPinned(thread.threadId, false)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw CodexError.invalidState }
        if existing.isEmpty {
            let content = ActivityContent(state: PinnedThreadAttributes.ContentState(summary: "等待同步", updatedAt: Date()), staleDate: Date(timeIntervalSinceNow: 1200))
            _ = try Activity.request(attributes: PinnedThreadAttributes(threadId: thread.threadId, title: thread.displayName, accountScope: scope), content: content, pushType: nil)
        }
        try await ThreadSyncClient.liveValue.setPinned(thread.threadId, true)
    }

    public static func updatePinned(_ result: MobileSyncResult) async {
        guard let scope = try? MobileSyncEngine.scope() else { return }
        for activity in Activity<PinnedThreadAttributes>.activities {
            let id = activity.attributes.threadId
            guard activity.attributes.accountScope == scope, result.metadata[id]?.pinned == true else {
                await activity.end(nil, dismissalPolicy: .immediate); continue
            }
            guard let metadata = result.metadata[id], let synced = metadata.lastSyncedAt,
                  !metadata.isRebuilding else { continue }
            let events = (try? await ThreadSyncClient.liveValue.cachedEvents(id)) ?? []
            let latestState = events.reversed().first(where: { $0.type == "job.state" || $0.type == "job.finished" })?.payloadString("state")
            let terminal = ["DONE", "FAILED", "CANCELLED"].contains(latestState ?? "")
            let nativeWaiting = result.threads.first(where: { $0.threadId == id })?.executionState == "WAITING_APPROVAL"
            let summary = terminal ? "任务已结束" : (nativeWaiting ? "等待原生确认" : (latestState == "WAITING_APPROVAL" ? "等待你确认" : "任务进行中"))
            let content = ActivityContent(state: PinnedThreadAttributes.ContentState(summary: summary, updatedAt: synced), staleDate: synced.addingTimeInterval(1200))
            if terminal {
                await activity.end(content, dismissalPolicy: .after(Date(timeIntervalSinceNow: 60)))
                try? await ThreadSyncClient.liveValue.setPinned(id, false)
            } else { await activity.update(content) }
        }
    }
}
