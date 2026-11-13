import Foundation
import UserNotifications
import os

/// Native notifications. Falls back to the unified log when not authorized.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "dev.codesmith28.hyprmac", category: "notify")
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter requires a real bundle; a bare binary would crash.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [logger] granted, error in
            logger.info("notification authorization granted=\(granted) error=\(String(describing: error))")
        }
    }

    /// Called on the main thread when the user clicks a notification that carries an action.
    var onAction: ((NotificationAction) -> Void)?

    func post(title: String, body: String, id: String = UUID().uuidString, action: NotificationAction? = nil) {
        logger.notice("\(title, privacy: .public): \(body, privacy: .public)")
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let action { content.userInfo = [NotificationAction.userInfoKey: action.rawValue] }
        // Re-using the identifier replaces an older notice instead of stacking duplicates.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let action = NotificationAction(userInfo: response.notification.request.content.userInfo) {
            DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        }
        completionHandler()
    }

    // Show banners even though we're an accessory app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
