import CoreGraphics
import Foundation

/// Native Space id (`CGSSpaceID`) or a synthetic id when SkyLight is unavailable.
public typealias SpaceID = UInt64
/// `CGDirectDisplayID`.
public typealias DisplayID = CGDirectDisplayID

/// Identity of one window: owning process plus window-server id.
/// A relaunched app that reuses a `CGWindowID` yields a *different* `WindowRef` (new pid).
public struct WindowRef: Hashable, Sendable, CustomStringConvertible {
    public let pid: pid_t
    public let windowID: CGWindowID
    public init(pid: pid_t, windowID: CGWindowID) {
        self.pid = pid
        self.windowID = windowID
    }
    public var description: String { "\(pid):\(windowID)" }
}

/// Mirrors `NSApplication.ActivationPolicy` without importing AppKit into the model.
public enum ActivationPolicy: Int, Sendable {
    case regular = 0, accessory = 1, prohibited = 2
}

/// Everything the AX layer knows about one window. Frames are top-left global points.
public struct WindowFacts: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var frame: CGRect
    public var isMinimized: Bool
    public var isFullscreen: Bool
    /// `AXSize` is settable.
    public var isResizable: Bool
    public var isMain: Bool
    public var isFocused: Bool
    public var bundleID: String?
    public var activationPolicy: ActivationPolicy
    public var hasCloseButton: Bool
    /// Minimum size when the app exposes one (rare); `nil` when unknown.
    public var minSize: CGSize?

    public init(role: String = "AXWindow", subrole: String? = "AXStandardWindow", title: String? = nil,
                frame: CGRect, isMinimized: Bool = false, isFullscreen: Bool = false,
                isResizable: Bool = true, isMain: Bool = false, isFocused: Bool = false,
                bundleID: String? = nil, activationPolicy: ActivationPolicy = .regular,
                hasCloseButton: Bool = true, minSize: CGSize? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isResizable = isResizable
        self.isMain = isMain
        self.isFocused = isFocused
        self.bundleID = bundleID
        self.activationPolicy = activationPolicy
        self.hasCloseButton = hasCloseButton
        self.minSize = minSize
    }
}

/// Mirrors `hm_window_state` (raw values are identical, so HyprKit can convert with `rawValue`).
public enum WindowState: Int32, Sendable, CaseIterable {
    case tiled = 0
    case floating = 1
    case minimized = 2
    case fullscreen = 3
    case hidden = 4

    /// States that keep a ghost slot in the engine.
    public var isGhost: Bool { self == .minimized || self == .fullscreen || self == .hidden }
}

/// Information about a running application.
public struct AppInfo: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String?
    public var activationPolicy: ActivationPolicy
    public var isHidden: Bool
    public init(pid: pid_t, bundleID: String?, activationPolicy: ActivationPolicy = .regular, isHidden: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.activationPolicy = activationPolicy
        self.isHidden = isHidden
    }
}

/// One display. Both frames are top-left global points.
public struct DisplayInfo: Equatable, Sendable {
    public var id: DisplayID
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var isMain: Bool
    public init(id: DisplayID, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

public enum SpaceKind: Equatable, Sendable {
    case user
    case fullscreen
}

/// One native Space.
public struct SpaceInfo: Equatable, Sendable {
    public var id: SpaceID
    public var display: DisplayID
    public var kind: SpaceKind
    /// 1-based index among the *user* Spaces of the display; `nil` for fullscreen Spaces.
    public var index: Int?
    public init(id: SpaceID, display: DisplayID, kind: SpaceKind, index: Int?) {
        self.id = id
        self.display = display
        self.kind = kind
        self.index = index
    }
}

/// One entry of `CGWindowListCopyWindowInfo`.
public struct OnscreenWindow: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: pid_t
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public var isOnscreen: Bool
    public init(id: CGWindowID, pid: pid_t, layer: Int = 0, bounds: CGRect, alpha: Double = 1, isOnscreen: Bool = true) {
        self.id = id
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
        self.isOnscreen = isOnscreen
    }
}

// MARK: - Geometry helpers

extension CGRect {
    /// Every edge within `tolerance` points.
    public func isApproximately(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
