import Foundation
import HyprControl
import HyprPlatform

/// Maps control commands onto the running tiler. Thread-safe: `TilingController` calls are
/// asynchronous hops onto the coordinator queue, and `isPaused` is lock-protected.
public final class TilingControlHandler: ControlHandler {
    private let controller: TilingController
    private let version: String
    private let configPath: String
    private let displays: DisplayProvider
    private let spaces: SpaceProvider
    /// `NSScreen` is read on the main thread; tests run inline.
    private let onMain: (@escaping () -> Void) -> Void

    public init(controller: TilingController, version: String, configPath: String,
                displays: DisplayProvider = SystemDisplayProvider(),
                spaces: SpaceProvider = SkyLightSpaceProvider(),
                onMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.controller = controller; self.version = version; self.configPath = configPath
        self.displays = displays; self.spaces = spaces; self.onMain = onMain
    }

    public func handle(_ command: ControlCommand) -> ControlReply {
        switch command {
        case .status: return status()
        case .retile: controller.retileAll(); return .success()
        case .pause: controller.setPaused(true, reason: "user"); return .success()
        case .resume: controller.setPaused(false, reason: nil); return .success()
        case .togglePause: controller.setPaused(!controller.isPaused, reason: "user"); return .success()
        case .reload: controller.reloadConfig(); return .success()
        }
    }

    private func status() -> ControlReply {
        var counts: (displays: Int, spaces: Int?)?
        let done = DispatchSemaphore(value: 0)
        onMain { [self] in
            let list = displays.displays()
            var total: Int? = spaces.isNativeSpacesAvailable ? 0 : nil
            if total != nil { for d in list { total! += spaces.spaceCount(display: d.id) ?? 0 } }
            counts = (list.count, total)
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success, let counts else { return .failure("status timed out") }
        var result: [String: Any] = [
            "version": version,
            "paused": controller.isPaused,
            "displays": counts.displays,
            "config": configPath,
        ]
        if let s = counts.spaces { result["spaces"] = s } else { result["spaces"] = NSNull() }
        return .success(result)
    }
}
