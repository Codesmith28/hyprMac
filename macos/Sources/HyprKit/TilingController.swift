import Foundation
import HyprPlatform

/// What the app shell needs from the tiling machinery. Implemented by `Coordinator`.
public protocol TilingController: AnyObject {
    var isPaused: Bool { get }
    var osdPopup: Bool { get }
    /// The live shortcuts (from the loaded config).
    var keyBindings: KeyBindings { get }
    var delegate: TilingControllerDelegate? { get set }
    func start()
    func stop()
    func setPaused(_ paused: Bool, reason: String?)
    /// Same as the menu item: pause when running, resume when paused (`keys.toggle_pause`).
    func togglePause()
    func retileAll()
    func reloadConfig()
}

/// The target floating state when a window's state is toggled.
public enum WindowToggleState: String, Equatable, Sendable, CustomStringConvertible {
    case floating
    case tiled

    public var description: String { rawValue }
}

/// User-visible notices the shell turns into notifications / menu state.
public enum TilingNotice: Equatable {
    case missingSpace(requested: Int, count: Int)
    case throwFailed(requested: Int, reason: String)
    case configError(String)
    case configLoaded
    case stageManagerEnabled
    case conflictingApp(name: String)
    /// More than one display is connected but "Displays have separate Spaces" is off.
    case separateSpacesOff
    case permissionLost
    /// Some configured shortcuts could not be registered (another app owns them).
    case hotkeysUnavailable(String)
    /// `keys.switch` doesn't match any enabled native "Switch to Desktop N" shortcut.
    case switchShortcutMismatch(configured: String, native: [String])
    /// Active application window state toggled between floating and tiled.
    case windowStateToggled(app: String?, state: WindowToggleState)
    /// Focused window centered on the active display.
    case windowCentered(app: String?)
    /// Switched to Desktop / Workspace N.
    case spaceSwitched(toSpace: Int)
    /// Focused window thrown to Desktop / Workspace N.
    case windowThrown(app: String?, fromSpace: Int?, toSpace: Int)
}

public protocol TilingControllerDelegate: AnyObject {
    func tiling(_ controller: TilingController, didPost notice: TilingNotice)
    func tilingStateChanged(_ controller: TilingController)
}
