import Foundation

/// Where clicking a notification takes the user. Stored in the notification's `userInfo`.
enum NotificationAction: String {
    case accessibility, inputMonitoring, keyboardShortcuts, config

    static let userInfoKey = "action"

    /// System Settings pane for the permission / shortcut actions; `.config` opens the file instead.
    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .keyboardShortcuts:
            return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case .config:
            return nil
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.userInfoKey] as? String, let a = NotificationAction(rawValue: raw) else { return nil }
        self = a
    }
}
