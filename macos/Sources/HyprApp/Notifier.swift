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

    func post(title: String, body: String, id: String = UUID().uuidString) {
        logger.notice("\(title, privacy: .public): \(body, privacy: .public)")
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Re-using the identifier replaces an older notice instead of stacking duplicates.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show banners even though we're an accessory app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
