@preconcurrency import ActivityKit
import CodexActivityModels
import Foundation

@MainActor
enum RemoteLiveActivities {
    private static var watchers: [String: [Task<Void, Never>]] = [:]
    private static var uploaded: [String: String] = [:]
    private static var attempted: [String: Date] = [:]

    static func observe(_ activity: Activity<PinnedThreadAttributes>) {
        guard (try? MobileSyncEngine.scope()) == activity.attributes.accountScope,
              [.active, .stale].contains(activity.activityState) else { return }
        if watchers[activity.id] == nil {
            let tokens = Task {
                for await token in activity.pushTokenUpdates {
                    if Task.isCancelled { break }
                    await upload(token, activity: activity)
                }
            }
            let states = Task {
                for await state in activity.activityStateUpdates {
                    if Task.isCancelled { break }
                    if state == .ended || state == .dismissed {
                        stop(activity)
                        if (try? MobileSyncEngine.scope()) == activity.attributes.accountScope {
                            try? await ThreadSyncClient.liveValue.setPinned(activity.attributes.threadId,false)
                        }
                        break
                    }
                }
            }
            watchers[activity.id] = [tokens, states]
        }
        if let token = activity.pushToken { Task { await upload(token, activity: activity) } }
    }

    static func stop(_ activity: Activity<PinnedThreadAttributes>) {
        watchers.removeValue(forKey: activity.id)?.forEach { $0.cancel() }
        uploaded.removeValue(forKey: activity.id)
        attempted = attempted.filter { !$0.key.hasPrefix(activity.id + ":") }
        guard (try? MobileSyncEngine.scope()) == activity.attributes.accountScope,
              let config = WorkerConfiguration.load() else { return }
        let scope = RemotePushRegistrationService.binding(for: activity.attributes.accountScope)
        // The local activity has already ended. APNs cannot recreate it if this
        // best-effort unregister is offline or a prior upload was in flight.
        Task { try? await send(config, path: "unregister", body: ["id":activity.id,"clientScope":scope]) }
    }

    private static func upload(_ token: Data, activity: Activity<PinnedThreadAttributes>) async {
        guard !Task.isCancelled, [.active, .stale].contains(activity.activityState),
              (try? MobileSyncEngine.scope()) == activity.attributes.accountScope,
              let config = WorkerConfiguration.load() else { return }
        let hex = token.map { String(format:"%02x",$0) }.joined()
        let attemptKey = activity.id + ":" + hex
        guard uploaded[activity.id] != hex, Date().timeIntervalSince(attempted[attemptKey] ?? .distantPast) >= 60 else { return }
        attempted[attemptKey] = Date()
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let body: [String: Any] = ["id":activity.id,"threadId":activity.attributes.threadId,"token":hex,"pinned":true,
            "clientScope":RemotePushRegistrationService.binding(for:activity.attributes.accountScope),"environment":environment]
        do {
            try await send(config, path:"register", body:body)
            if !Task.isCancelled && [.active,.stale].contains(activity.activityState) { uploaded[activity.id] = hex }
        } catch { /* Local updates and stale-date remain usable; retry only on a later foreground opportunity. */ }
    }

    private static func send(_ config: WorkerConfiguration, path: String, body: [String: Any]) async throws {
        guard let url = URL(string:config.baseURL + "/v1/live-activities/" + path), let token = config.token, !token.isEmpty else {
            throw CodexError.notConfigured
        }
        var request = URLRequest(url:url,timeoutInterval:12)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject:body)
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization")
        let (_, response) = try await URLSession.shared.data(for:request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
    }
}
