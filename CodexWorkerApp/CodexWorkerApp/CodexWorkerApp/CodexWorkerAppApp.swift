//
//  CodexWorkerAppApp.swift
//  CodexWorkerApp
//
//  Created by  Apple on 2/15/26.
//

import SwiftUI
import UIKit
import UserNotifications
import CodexWorker

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
        UNUserNotificationCenter.current().delegate = self
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
        print("[Push] didFailToRegisterForRemoteNotifications: \(error.localizedDescription)")
#endif
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    private func requestPushAuthorizationAndRegister(_ application: UIApplication) {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                #if DEBUG
                print("[Push] requestAuthorization failed: \(error.localizedDescription)")
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
