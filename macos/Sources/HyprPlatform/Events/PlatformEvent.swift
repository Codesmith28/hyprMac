import CoreGraphics
import Foundation

/// What happened to a window (from an `AXObserver`).
public enum WindowEventKind: Equatable, Sendable {
    case created, destroyed, focused, mainChanged, moved, resized, miniaturized, deminiaturized
}

/// Every platform signal the coordinator consumes, delivered through one callback.
public enum PlatformEvent: Equatable, Sendable {
    /// `window` is nil when the element's id couldn't be resolved (e.g. destroyed before
    /// it was ever seen).
    case window(WindowEventKind, pid: pid_t, window: WindowRef?)
    case appLaunched(pid_t, bundleID: String?)
    case appTerminated(pid_t)
    case appHidden(pid_t)
    case appShown(pid_t)
    case appActivated(pid_t)
    case activeSpaceChanged
    case screenParametersChanged
    case userDragBegan(CGPoint)
    case userDragEnded(CGPoint)
    /// AX observer registration kept failing after every retry.
    case observerRegistrationFailed(pid_t)
}

/// AX notification names (the `kAX…Notification` string values).
public enum AXNotificationName {
    public static let windowCreated = "AXWindowCreated"
    public static let uiElementDestroyed = "AXUIElementDestroyed"
    public static let focusedWindowChanged = "AXFocusedWindowChanged"
    public static let mainWindowChanged = "AXMainWindowChanged"
    public static let windowMoved = "AXWindowMoved"
    public static let windowResized = "AXWindowResized"
    public static let windowMiniaturized = "AXWindowMiniaturized"
    public static let windowDeminiaturized = "AXWindowDeminiaturized"
    public static let applicationHidden = "AXApplicationHidden"
    public static let applicationShown = "AXApplicationShown"
    public static let applicationActivated = "AXApplicationActivated"

    /// Registered on the application element.
    public static let appLevel = [windowCreated, focusedWindowChanged, mainWindowChanged, windowMoved,
                                  windowResized, windowMiniaturized, windowDeminiaturized,
                                  applicationHidden, applicationShown, applicationActivated]
    /// Registered on each window element.
    public static let windowLevel = [uiElementDestroyed]

    /// Pure mapping from a notification to an event. Unknown names map to nil.
    public static func event(for name: String, pid: pid_t, window: WindowRef?) -> PlatformEvent? {
        switch name {
        case windowCreated: return .window(.created, pid: pid, window: window)
        case uiElementDestroyed: return .window(.destroyed, pid: pid, window: window)
        case focusedWindowChanged: return .window(.focused, pid: pid, window: window)
        case mainWindowChanged: return .window(.mainChanged, pid: pid, window: window)
        case windowMoved: return .window(.moved, pid: pid, window: window)
        case windowResized: return .window(.resized, pid: pid, window: window)
        case windowMiniaturized: return .window(.miniaturized, pid: pid, window: window)
        case windowDeminiaturized: return .window(.deminiaturized, pid: pid, window: window)
        case applicationHidden: return .appHidden(pid)
        case applicationShown: return .appShown(pid)
        case applicationActivated: return .appActivated(pid)
        default: return nil
        }
    }
}

/// Marker stored in `eventSourceUserData` of every event hyprMac posts, so our own listeners
/// (drag monitor, Space-key tap) can ignore them.
public enum SyntheticEventMarker {
    public static let value: Int64 = 0x4859_5052 // "HYPR"
    public static func isSynthetic(userData: Int64) -> Bool { userData == value }
}
