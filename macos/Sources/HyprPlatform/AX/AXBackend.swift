import ApplicationServices
import CoreGraphics
import Foundation

/// Typed `AXError`s the platform layer cares about.
public enum AXBackendError: Error, Equatable, Sendable {
    /// App busy/hung or not ready (also the messaging-timeout result). Retryable.
    case cannotComplete
    /// The element is gone (window closed).
    case invalidUIElement
    case attributeUnsupported
    case notImplemented
    /// Accessibility is not trusted.
    case apiDisabled
    case noValue
    /// The window has no element in the backend (e.g. not enumerated yet).
    case unknownWindow
    case other(Int32)

    public init(_ error: AXError) {
        switch error {
        case .cannotComplete: self = .cannotComplete
        case .invalidUIElement: self = .invalidUIElement
        case .attributeUnsupported: self = .attributeUnsupported
        case .notImplemented: self = .notImplemented
        case .apiDisabled: self = .apiDisabled
        case .noValue: self = .noValue
        default: self = .other(error.rawValue)
        }
    }

    /// Worth retrying later (app busy / window not ready).
    public var isRetryable: Bool { self == .cannotComplete }
}

/// Boolean window attributes the backend can read and write.
public enum AXBoolAttribute: String, Sendable, CaseIterable {
    case minimized = "AXMinimized"
    case fullscreen = "AXFullScreen"
    case main = "AXMain"
    case focused = "AXFocused"
}

/// Result of an element-at-position hit test.
public struct AXHit: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var pid: pid_t
    /// The window the element belongs to (or is), when resolvable.
    public var window: WindowRef?
    /// The hit element *is* the window element itself.
    public var isWindowItself: Bool
    public init(role: String, subrole: String? = nil, pid: pid_t, window: WindowRef?, isWindowItself: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.pid = pid
        self.window = window
        self.isWindowItself = isWindowItself
    }
}

/// Thin wrapper over `AXUIElement`, addressed by `WindowRef` / pid so it can be faked.
///
/// All methods are synchronous, may block up to the app's messaging timeout, and must be
/// safe to call from any thread. Frames are top-left global points.
public protocol AXBackend: AnyObject {
    /// `AXIsProcessTrustedWithOptions`; `prompt` shows the system dialog.
    func isTrusted(prompt: Bool) -> Bool
    /// Per-app messaging timeout hint. `SystemAXBackend` ignores it: its timeout is process-wide
    /// (set once on the system-wide element), because a timeout set on one element instance never
    /// reaches the others. Fakes use it to model how long a hung app blocks.
    func setMessagingTimeout(pid: pid_t, seconds: Float)
    /// Drop every cached element of a terminated app.
    func forget(pid: pid_t)
    /// The app's windows (AX order, front to back). Windows without a resolvable id are omitted.
    func windows(pid: pid_t) throws -> [WindowRef]
    func facts(of window: WindowRef) throws -> WindowFacts
    func frame(of window: WindowRef) throws -> CGRect
    func setPosition(_ origin: CGPoint, of window: WindowRef) throws
    func setSize(_ size: CGSize, of window: WindowRef) throws
    func bool(_ attribute: AXBoolAttribute, of window: WindowRef) throws -> Bool
    func setBool(_ attribute: AXBoolAttribute, _ value: Bool, of window: WindowRef) throws
    func raise(_ window: WindowRef) throws
    /// Bounding boxes of the window's traffic light buttons (close, minimize, zoom/fullscreen) when available.
    func trafficLightButtons(of window: WindowRef) -> (close: CGRect?, minimize: CGRect?, zoom: CGRect?)
    /// `AXEnhancedUserInterface` on the application element.
    func enhancedUserInterface(pid: pid_t) throws -> Bool
    func setEnhancedUserInterface(_ value: Bool, pid: pid_t) throws
    func focusedApplication() throws -> pid_t?
    func focusedWindow(pid: pid_t) throws -> WindowRef?
    /// `AXUIElementCopyElementAtPosition` on the system-wide element.
    func element(at point: CGPoint) throws -> AXHit?
}

public extension AXBackend {
    func trafficLightButtons(of window: WindowRef) -> (close: CGRect?, minimize: CGRect?, zoom: CGRect?) {
        (nil, nil, nil)
    }
}
