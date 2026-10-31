import Foundation

/// What the app shell needs from the tiling machinery. Implemented by `Coordinator`.
public protocol TilingController: AnyObject {
    var isPaused: Bool { get }
    var delegate: TilingControllerDelegate? { get set }
    func start()
    func stop()
    func setPaused(_ paused: Bool, reason: String?)
    func retileAll()
    func reloadConfig()
}

/// User-visible notices the shell turns into notifications / menu state.
public enum TilingNotice: Equatable {
    case missingSpace(requested: Int, count: Int)
    case throwFailed(requested: Int, reason: String)
    case configError(String)
    case configLoaded
    case stageManagerEnabled
    case conflictingApp(name: String)
    case permissionLost
}

public protocol TilingControllerDelegate: AnyObject {
    func tiling(_ controller: TilingController, didPost notice: TilingNotice)
    func tilingStateChanged(_ controller: TilingController)
}
