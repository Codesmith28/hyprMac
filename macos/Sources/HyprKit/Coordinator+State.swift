import CoreGraphics
import Foundation
import HyprPlatform

/// Application state persistence (floating / tiled / fullscreen) across app close/reopen.
extension Coordinator {

    /// Retrieves the bundle ID for a window ref.
    func bundleID(for ref: HyprPlatform.WindowRef) -> String? {
        deps.apps.application(pid: ref.pid)?.bundleID
            ?? deps.apps.runningApplications().first(where: { $0.pid == ref.pid })?.bundleID
    }

    /// Retrieves the bundle ID for an engine ID.
    func bundleID(for id: UInt64) -> String? {
        guard let ref = identity.ref(forEngineID: id) else { return nil }
        return bundleID(for: ref)
    }

    /// Restores saved state for an app when first evaluated:
    /// - If `.floating`: apply `floatOverride[id] = true` and use the saved frame if available.
    /// - If `.tiled`: apply `floatOverride[id] = false`.
    func restoreSavedStateIfNeeded(id: UInt64, ref: HyprPlatform.WindowRef? = nil,
                                   platform: WindowState, frame: CGRect) {
        guard !stateRestored.contains(id) else { return }
        stateRestored.insert(id)

        guard let windowRef = ref ?? identity.ref(forEngineID: id),
              let bundle = bundleID(for: windowRef),
              let saved = appStateStore.savedState(for: bundle) else { return }

        switch saved.state {
        case .floating:
            floatOverride[id] = true
            if let savedFrame = saved.frame, savedFrame.width > 0, savedFrame.height > 0 {
                firstSeenFrame[id] = savedFrame
                executor.place(windowRef, frame: savedFrame)
            }
        case .tiled:
            floatOverride[id] = false
        case .fullscreen:
            break
        }
    }

    /// Tracks fullscreen transitions and updates `appStateStore` accordingly.
    func noteWindowStateChanged(id: UInt64, oldState: Engine.TileState?, newState: Engine.TileState, frame: CGRect?) {
        guard let bundle = bundleID(for: id) else { return }
        if newState == .fullscreen {
            if oldState != .fullscreen {
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .fullscreen))
            }
        } else if oldState == .fullscreen {
            if newState == .floating {
                let f = firstSeenFrame[id] ?? frame
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .floating, frame: f))
            } else if newState == .tiled {
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .tiled))
            }
        }
    }
}
