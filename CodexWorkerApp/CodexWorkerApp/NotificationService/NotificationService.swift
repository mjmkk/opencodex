import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var completion: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        completion = contentHandler
        fallback = request.content
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { finish(); return }
        // Bounded local enhancement only. Network failure cannot hide the original alert,
        // and notification rendering never decides whether an approval is still valid.
        if request.content.userInfo["approvalId"] is String {
            content.subtitle = "请先查看当前请求的范围"
        }
        if content.body.isEmpty { content.body = "打开 OpenCodex 查看原任务的最新内容。" }
        fallback = content
        finish()
    }

    override func serviceExtensionTimeWillExpire() { finish() }
    private func finish() {
        if let handler = completion, let content = fallback {
            completion = nil
            handler(content)
        }
    }
}
