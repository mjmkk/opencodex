@preconcurrency import ActivityKit
@preconcurrency import BackgroundTasks
import CodexActivityModels
import Foundation
import OSLog

@MainActor
public enum MobileLifecycle {
    public static let openNativeRequestNotification = Notification.Name("opencodex.openNativeRequest")
    public static func openNativeRequest(_ route: NativeRequestRoute) {
        guard let data = try? JSONEncoder().encode(route) else { return }
        UserDefaults.standard.set(data, forKey: "opencodex.pendingNativeRequest")
        NotificationCenter.default.post(name: openNativeRequestNotification, object: route)
    }
    public static func takePendingNativeRequest() -> NativeRequestRoute? {
        defer { UserDefaults.standard.removeObject(forKey: "opencodex.pendingNativeRequest") }
        guard let data = UserDefaults.standard.data(forKey: "opencodex.pendingNativeRequest") else { return nil }
        return try? JSONDecoder().decode(NativeRequestRoute.self, from: data)
    }
    public static let openThreadNotification = Notification.Name("opencodex.openThread")
    public static func recordNotificationResult(_ message: String) {
        UserDefaults.standard.set(message, forKey: "opencodex.notificationResult")
    }
    public static func takeNotificationResult() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: "opencodex.notificationResult") }
        return UserDefaults.standard.string(forKey: "opencodex.notificationResult")
    }
    private static let pendingKey = "opencodex.pendingNotificationThread"
    private static let refreshID = (Bundle.main.bundleIdentifier ?? "li.CodexWorkerApp") + ".refresh"
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

    /// Only the explicit Pin action creates an Activity. Sync and notifications never create one.
    public static func setPinned(_ pinned: Bool, thread: Thread) async throws {
        let scope = try MobileSyncEngine.scope()
        let existing = Activity<PinnedThreadAttributes>.activities.filter {
            $0.attributes.threadId == thread.threadId && $0.attributes.accountScope == scope &&
                [.active, .stale].contains($0.activityState)
        }
        if !pinned {
            try await ThreadSyncClient.liveValue.setPinned(thread.threadId, false)
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
                RemoteLiveActivities.stop(activity)
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw CodexError.invalidState }
        // Save intent before requesting the system activity; a concurrent refresh must not end it
        // using an older metadata snapshot in which this explicit Pin did not yet exist.
        try await ThreadSyncClient.liveValue.setPinned(thread.threadId, true)
        do {
            if existing.isEmpty {
                let content = ActivityContent(state: PinnedThreadAttributes.ContentState(summary: "正在核对任务状态", updatedAt: Date()), staleDate: Date(timeIntervalSinceNow: 120))
                #if targetEnvironment(simulator)
                let activity = try Activity.request(attributes: PinnedThreadAttributes(threadId: thread.threadId, title: thread.displayName, accountScope: scope), content: content, pushType: nil)
                #else
                let activity = try Activity.request(attributes: PinnedThreadAttributes(threadId: thread.threadId, title: thread.displayName, accountScope: scope), content: content, pushType: .token)
                #endif
                RemoteLiveActivities.observe(activity)
            }
        } catch {
            try? await ThreadSyncClient.liveValue.setPinned(thread.threadId, false)
            throw error
        }
        if let result = try? await ThreadSyncClient.liveValue.cached() { await updatePinned(result) }
    }

    public static func updateNativeRequests(_ requests: [NativeRemoteRequest]) async {
        for group in Dictionary(grouping: requests, by: \.thread_id).values {
            if let request = group.first(where: { $0.response_available }) ?? group.first {
                await updateNativeRequest(request)
            }
        }
    }

    public static func updateNativeRequest(_ request: NativeRemoteRequest) async {
        guard let scope = try? MobileSyncEngine.scope() else { return }
        for activity in Activity<PinnedThreadAttributes>.activities where
            activity.attributes.accountScope == scope && activity.attributes.threadId == request.thread_id &&
            [.active, .stale].contains(activity.activityState) {
            let state: String
            if let terminal = request.native_terminal?.objectValue?["status"]?.stringValue {
                switch terminal {
                case "completed": state = "DONE"
                case "failed": state = "FAILED"
                case "interrupted", "cancelled": state = "CANCELLED"
                default: state = "REQUEST_UNAVAILABLE"
                }
            } else if request.native_resolution != nil { state = "REQUEST_RESOLVED" }
            else if request.response_submitted { state = "RESPONSE_SUBMITTED" }
            else if request.response_available { state = "WAITING_USER" }
            else { state = "REQUEST_UNAVAILABLE" }
            let destination = NativeRequestRoute(item: request)?.url?.absoluteString
            let sameObservation = activity.content.state.executionState == state && activity.content.state.requestURL == destination
            let observedAt = sameObservation ? activity.content.state.updatedAt : Date()
            let content = ActivityContent(state: PinnedThreadAttributes.ContentState(
                summary: PinnedThreadAttributes.ContentState.summary(for: state), updatedAt: observedAt,
                executionState: state, requestURL: destination),
                staleDate: Date(timeIntervalSinceNow: 120))
            if ["DONE", "FAILED", "CANCELLED"].contains(state) {
                await activity.end(content, dismissalPolicy: .after(Date(timeIntervalSinceNow: 60)))
                RemoteLiveActivities.stop(activity)
                try? await ThreadSyncClient.liveValue.setPinned(request.thread_id, false)
            } else { await activity.update(content); RemoteLiveActivities.observe(activity) }
        }
    }

    public static func updatePinned(_ result: MobileSyncResult) async {
        guard let scope = try? MobileSyncEngine.scope(),
              let current = try? await ThreadSyncClient.liveValue.cached() else { return }
        let native = try? await APIClient.live.nativeRequests().data
        guard (try? MobileSyncEngine.scope()) == scope else { return }
        for activity in Activity<PinnedThreadAttributes>.activities {
            let id = activity.attributes.threadId
            guard activity.attributes.accountScope == scope, current.metadata[id]?.pinned == true else {
                await activity.end(nil, dismissalPolicy: .immediate)
                RemoteLiveActivities.stop(activity)
                continue
            }
            if let request = native?.first(where: { $0.thread_id == id }) {
                await updateNativeRequest(request); continue
            }
            if let link = activity.content.state.requestURL, let url = URL(string: link),
               let route = NativeRequestRoute(url: url), let selection = route.selection {
                if let request = try? await APIClient.live.readNativeRequest(selection), route.matches(request) {
                    await updateNativeRequest(request)
                    // A resolved request is not proof that its turn resumed. Keep that distinction
                    // until a real later execution observation arrives from the original thread.
                    if request.native_terminal != nil || request.native_resolution == nil { continue }
                } else { continue } // Let the activity become stale rather than fabricate progress.
            }
            // A Thread cache refresh is not evidence that native execution resumed.
            // Keep request feedback until a new native observation arrives.
            if activity.content.state.requestURL != nil { continue }
            let content = ActivityContent(state: PinnedThreadAttributes.ContentState(
                summary: "已固定此任务", updatedAt: activity.content.state.updatedAt,
                executionState: "PINNED"), staleDate: activity.content.staleDate)
            await activity.update(content); RemoteLiveActivities.observe(activity)
        }
    }
}
