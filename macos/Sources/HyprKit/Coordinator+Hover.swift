import AppKit
import CoreGraphics
import Foundation
import HyprPlatform

/// `config.focus_follows_mouse`: hovering a managed window focuses it after `HoverFocusGate.debounce`.
/// Never warps the cursor, never refocuses the focused window, and stays quiet for a moment after any
/// cursor warp hyprMac itself made (focus_direction, throws, pins), so the two never fight.
extension Coordinator {

    /// Starts or stops the mouse monitor to match the config. On `queue`.
    func updateMouseMonitor() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let monitor = deps.mouseMonitor else { return }
        let want = running && currentConfig.focusFollowsMouse
        guard want != mouseMonitorRunning else { return }
        mouseMonitorRunning = want
        hoverGate.reset()
        deps.onMain { [weak self] in
            if want {
                if !monitor.start({ p in self?.mouseMoved(to: p) }) {
                    self?.logger.error("focus_follows_mouse: mouse monitor unavailable")
                }
            } else {
                monitor.stop()
            }
        }
    }

    func mouseMoved(to point: CGPoint) {
        queue.async { [self] in handleMouseMoved(point) }
    }

    /// On `queue`. Internal for tests.
    func handleMouseMoved(_ point: CGPoint) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard hoverActive else { return }
        if hoverGate.noteHover(managedWindow(at: point), now: deps.clock.now()) {
            schedule(after: hoverGate.debounce + 0.01) { [weak self] in self?.hoverCheck() }
        }
    }

    /// On `queue`. Focuses the resting candidate when it is due. Internal for tests.
    func hoverCheck() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard hoverActive else { hoverGate.reset(); return }
        guard hoverGate.candidate != nil else { return }
        let focused = resolveFocusedWindow()?.window
        guard let target = hoverGate.due(now: deps.clock.now(), focused: focused),
              let id = idByRef[target], lastStates[id] == .tiled || lastStates[id] == .floating else { return }
        activity += 1
        _ = try? deps.ax.raise(target)
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: .activateIgnoringOtherApps) }
        }
        trackedFocusedRef = target
        EventLog.shared.emit("focus_hover", ["window": Int(target.windowID)])
    }

    private var hoverActive: Bool {
        running && currentConfig.focusFollowsMouse && !userPaused && !stageManagerPaused && !dragging && !throwInFlight
    }

    /// The managed (tiled or floating) window under `point`; nil over the menu bar, Dock, popups,
    /// ignored apps or empty desktop.
    private func managedWindow(at point: CGPoint) -> HyprPlatform.WindowRef? {
        for w in deps.windowServer.onscreenWindows() where w.isOnscreen && w.alpha > 0 && w.bounds.contains(point) {
            guard w.layer == 0 else { return nil }
            let ref = HyprPlatform.WindowRef(pid: w.pid, windowID: w.id)
            guard let id = idByRef[ref], let st = lastStates[id], st == .tiled || st == .floating else { return nil }
            return ref
        }
        return nil
    }

    // Test hooks
    func testMouseMoved(_ p: CGPoint) { queue.sync { handleMouseMoved(p) } }
    func testHoverCheck() { queue.sync { hoverCheck() } }
}
