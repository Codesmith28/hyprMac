import CoreGraphics
import Foundation

/// Why a window is not managed at all.
public enum ExclusionReason: Equatable, Sendable {
    case notRegularApp
    case ownApp
    case role(String)
    case subrole(String?)
    case layer(Int)
    case zeroSize
    case transparent
}

public enum Eligibility: Equatable, Sendable {
    case managed(WindowState)
    case excluded(ExclusionReason)

    public var state: WindowState? {
        if case .managed(let s) = self { return s }
        return nil
    }
}

/// Pure tiling-eligibility rules.
public enum WindowEligibility {
    /// hyprMac's own bundle id; its windows are never managed.
    public static let ownBundleID = "dev.codesmith28.hyprmac"

    /// Apps whose standard windows float by default.
    public static let defaultFloatBundleIDs: Set<String> = [
        "com.apple.archiveutility",
        "com.apple.calculator",
        "com.apple.systempreferences",
        "com.docker.docker",
        "com.mongodb.compass",
    ]

    public static let tiledRole = "AXWindow"
    public static let tiledSubrole = "AXStandardWindow"
    /// What a minimized standard window reports instead of `tiledSubrole`.
    public static let minimizedSubrole = "AXDialog"

    /// - Parameters:
    ///   - facts: AX facts for the window.
    ///   - onscreen: the window-server entry, when the window is on screen (nil when it is
    ///     minimized, hidden or on another Space — then layer/alpha aren't checked).
    ///   - app: the owning app.
    /// Rule order: app → role/subrole → zero size → minimized/fullscreen/hidden →
    /// layer/alpha → floating → tiled.
    public static func evaluate(_ facts: WindowFacts, onscreen: OnscreenWindow?, app: AppInfo,
                                ownBundleID: String? = ownBundleID,
                                floatBundleIDs: Set<String> = defaultFloatBundleIDs) -> Eligibility {
        if app.activationPolicy != .regular || facts.activationPolicy != .regular { return .excluded(.notRegularApp) }
        let bundle = app.bundleID ?? facts.bundleID
        if let own = ownBundleID, bundle == own { return .excluded(.ownApp) }
        // Sheets (AXSheet), popovers (AXPopover), drawers etc. have a non-window role.
        guard facts.role == tiledRole else { return .excluded(.role(facts.role)) }
        // AXDialog, AXSystemDialog, AXFloatingWindow, AXUnknown, no subrole (Finder desktop), ...
        // A minimized standard window reports "AXDialog" (observed on macOS 26): without this it
        // would vanish from the snapshot, the engine would forget its slot instead of ghosting it,
        // and unminimizing would dwindle-insert it somewhere else.
        let minimizedQuirk = facts.isMinimized && facts.subrole == minimizedSubrole
        guard facts.subrole == tiledSubrole || minimizedQuirk else { return .excluded(.subrole(facts.subrole)) }
        if facts.frame.width <= 0 || facts.frame.height <= 0 { return .excluded(.zeroSize) }

        if facts.isMinimized { return .managed(.minimized) }
        if facts.isFullscreen { return .managed(.fullscreen) }
        if app.isHidden { return .managed(.hidden) }

        if let o = onscreen {
            if o.layer != 0 { return .excluded(.layer(o.layer)) }
            if o.alpha <= 0 { return .excluded(.transparent) }
            if o.bounds.width <= 0 || o.bounds.height <= 0 { return .excluded(.zeroSize) }
        }

        if !facts.isResizable || !facts.hasCloseButton { return .managed(.floating) }
        if let b = bundle, floatBundleIDs.contains(b) { return .managed(.floating) }
        return .managed(.tiled)
    }
}
