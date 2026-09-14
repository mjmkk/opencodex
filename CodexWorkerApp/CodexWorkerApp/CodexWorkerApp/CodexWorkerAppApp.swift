//
//  CodexWorkerAppApp.swift
//  CodexWorkerApp
//
//  Created by mjmk on 2/15/26.
//

import SwiftUI
import UIKit
import UserNotifications
import CodexWorker
import OSLog

@main
struct CodexWorkerAppApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationAppDelegate

    var body: some Scene {
        WindowGroup {
            WorkerRootView()
        }
    }
}

final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MobileLifecycle.registerBackgroundRefresh()
        UNUserNotificationCenter.current().delegate = self
        let view = UNNotificationAction(identifier: "VIEW_CONTEXT", title: "查看请求", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "AGT_APPROVAL", actions: [view], intentIdentifiers: []),
            UNNotificationCategory(identifier: "AGT_THREAD", actions: [], intentIdentifiers: []),
        ])
        requestPushAuthorizationAndRegister(application)
        Task {
            await RemotePushRegistrationService.flushPendingRegistration()
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task {
            await RemotePushRegistrationService.flushPendingRegistration()
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            await RemotePushRegistrationService.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
#if DEBUG
        Logger(subsystem: "OpenCodex", category: "Push").error("Push registration failed: \(error.localizedDescription, privacy: .public)")
#endif
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        MobileLifecycle.scheduleBackgroundRefresh()
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            do {
                let id = userInfo["threadId"] as? String
                let result = try await ThreadSyncClient.liveValue.sync(id.map { [$0] } ?? [], true)
                await MobileLifecycle.updatePinned(result)
                completionHandler(result.changedThreadIds.isEmpty ? .noData : .newData)
            } catch { completionHandler(.failed) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["source"] as? String == "structured_approval" {
            MobileLifecycle.openApprovals()
        } else if let id = response.notification.request.content.userInfo["threadId"] as? String {
            MobileLifecycle.openThread(id)
        }
        completionHandler()
    }

    private func requestPushAuthorizationAndRegister(_ application: UIApplication) {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                #if DEBUG
                Logger(subsystem: "OpenCodex", category: "Push").error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                #endif
                return
            }

            guard granted else { return }
            await MainActor.run {
                application.registerForRemoteNotifications()
            }
        }
    }
}
