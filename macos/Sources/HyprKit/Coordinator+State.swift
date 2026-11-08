import AppKit
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

    /// Retrieves the display name (or bundle ID) for a window ref.
    func appDisplayName(for ref: HyprPlatform.WindowRef) -> String? {
        if let name = deps.apps.application(pid: ref.pid)?.name, !name.isEmpty {
            return name
        }
        if let name = NSRunningApplication(processIdentifier: ref.pid)?.localizedName, !name.isEmpty {
            return name
        }
        return bundleID(for: ref)
    }

    /// Retrieves the display name (or bundle ID) for an engine ID.
    func appDisplayName(for id: UInt64) -> String? {
        guard let ref = identity.ref(forEngineID: id) else { return nil }
        return appDisplayName(for: ref)
    }

    /// Restores saved state for an app when first evaluated:
    /// - If `.floating`: apply `floatOverride[id] = true` and use the saved frame if available.
    /// - If `.tiled`: apply `floatOverride[id] = false`.
    func restoreSavedStateIfNeeded(id: UInt64, ref: HyprPlatform.WindowRef? = nil,
                                   platform: WindowState, frame: CGRect) {
        guard !stateRestored.contains(id) else { return }
        stateRestored.insert(id)

        guard let windowRef = ref ?? identity.ref(forEngineID: id),
              let bundle = bundleID(for: windowRef) else { return }

        if let saved = appStateStore.savedState(for: bundle) {
            switch saved.state {
            case .floating:
                floatOverride[id] = true
                if let savedFrame = saved.frame, savedFrame.width > 0, savedFrame.height > 0 {
                    firstSeenFrame[id] = savedFrame
                    executor.place(windowRef, frame: savedFrame)
                }
            case .tiled:
                floatOverride[id] = false
                if let savedFrame = saved.frame, savedFrame.width > 0, savedFrame.height > 0 {
                    firstSeenFrame[id] = savedFrame
                }
            case .fullscreen:
                break
            }
        } else if platform == .floating, frame.width > 0, frame.height > 0 {
            // Natively floating window without prior saved state: save initial dimensions
            firstSeenFrame[id] = frame
            appStateStore.save(bundleID: bundle, state: SavedAppState(state: .floating, frame: frame))
        }
    }

    /// Tracks fullscreen transitions and updates `appStateStore` accordingly.
    func noteWindowStateChanged(id: UInt64, oldState: Engine.TileState?, newState: Engine.TileState, frame: CGRect?) {
        guard let bundle = bundleID(for: id) else { return }
        let currentFrame = firstSeenFrame[id] ?? frame
        if newState == .fullscreen {
            if oldState != .fullscreen {
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .fullscreen, frame: currentFrame))
            }
        } else if oldState == .fullscreen {
            if newState == .floating {
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .floating, frame: currentFrame))
            } else if newState == .tiled {
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .tiled, frame: currentFrame))
            }
        }
    }
}
