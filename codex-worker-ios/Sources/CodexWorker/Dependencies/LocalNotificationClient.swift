//
//  LocalNotificationClient.swift
//  CodexWorker
//
//  本地通知依赖（用于审批/任务完成提醒）
//

import ComposableArchitecture
import Foundation
import UserNotifications

public struct LocalNotificationRequest: Equatable, Sendable {
    public var identifier: String?
    public var title: String
    public var body: String
    public var threadIdentifier: String?

    public init(
        identifier: String? = nil,
        title: String,
        body: String,
        threadIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
    }
}

public struct LocalNotificationClient: DependencyKey, Sendable {
    public var requestAuthorization: @Sendable () async -> Bool
    public var schedule: @Sendable (_ request: LocalNotificationRequest) async -> Void

    public static let liveValue = LocalNotificationClient(
        requestAuthorization: {
            let center = UNUserNotificationCenter.current()
            do {
                return try await center.requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
            } catch {
                return false
            }
        },
        schedule: { request in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            if let threadIdentifier = request.threadIdentifier, !threadIdentifier.isEmpty {
                content.threadIdentifier = threadIdentifier
            }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
            let identifier = request.identifier ?? UUID().uuidString
            let notificationRequest = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(notificationRequest)
            } catch {
                // 通知失败不影响主流程
            }
        }
    )

    public static let testValue = LocalNotificationClient(
        requestAuthorization: { true },
        schedule: { _ in }
    )
}

extension DependencyValues {
    public var localNotificationClient: LocalNotificationClient {
        get { self[LocalNotificationClient.self] }
        set { self[LocalNotificationClient.self] = newValue }
    }
}
