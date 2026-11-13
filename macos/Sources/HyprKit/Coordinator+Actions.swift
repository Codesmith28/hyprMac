import AppKit
import CoreGraphics
import Foundation
import HyprPlatform

/// Unbound-by-default keyboard actions (`keys.resize_*`, `equalize`, `rotate_split`, `toggle_zoom`,
/// `move_display_next/prev`, `toggle_pause`). The tree math lives in the core; this wires focus,
/// plans and displays to it.
extension Coordinator {

    func perform(_ action: KeyAction) {
        switch action {
        case .resizeLeft: resizeFocused(.left)
        case .resizeDown: resizeFocused(.down)
        case .resizeUp: resizeFocused(.up)
        case .resizeRight: resizeFocused(.right)
        case .equalize: equalizeSpace()
        case .rotateSplit: rotateFocusedSplit()
        case .toggleZoom: toggleFocusedZoom()
        case .moveDisplayNext: moveFocusedToDisplay(next: true)
        case .moveDisplayPrev: moveFocusedToDisplay(next: false)
        case .togglePause: togglePause()
        }
    }

    public func resizeFocused(_ direction: Direction) {
        queue.async { [self] in
            guard let t = focusedTiled(), let plan = try? engine.resizeStep(window: t.id, direction: direction) else { return }
            apply(plan)
            EventLog.shared.emit("resize_step", ["window": Int(t.window.windowID), "direction": direction.rawValue])
        }
    }

    public func equalizeSpace() {
        queue.async { [self] in
            guard actionsAllowed() else { return }
            let space = focusedTiled()?.space ?? (activeSpaces.count == 1 ? activeSpaces.first : nil)
            guard let space, let plan = try? engine.equalize(space: space) else { return }
            apply(plan)
            EventLog.shared.emit("equalize", ["space": space])
        }
    }

    public func rotateFocusedSplit() {
        queue.async { [self] in
            guard let t = focusedTiled(), let plan = try? engine.rotateSplit(window: t.id) else { return }
            apply(plan)
            EventLog.shared.emit("rotate_split", ["window": Int(t.window.windowID)])
        }
    }

    public func toggleFocusedZoom() {
        queue.async { [self] in
            guard let t = focusedTiled(), let plan = try? engine.toggleZoom(window: t.id) else { return }
            apply(plan)
            let zoomed = engine.zoomedWindow(space: t.space) == t.id
            if zoomed { _ = try? deps.ax.raise(t.window) } // the others stay put underneath
            EventLog.shared.emit("toggle_zoom", ["window": Int(t.window.windowID), "zoomed": zoomed])
        }
    }

    /// Same as the menu item.
    public func togglePause() {
        queue.async { [self] in
            userPaused = !(userPaused || stageManagerPaused)
            updatePausedMirror()
            if userPaused { EventLog.shared.emit("paused", ["reason": "user"]) }
            stateChanged()
            if !userPaused { scheduleReconcile(after: 0) }
        }
    }

    /// Moves the focused window to the next/previous display (left to right, wrapping): into that
    /// display's current Space tree, reflowing both. Floating windows are re-centred there.
    public func moveFocusedToDisplay(next: Bool) {
        queue.async { [self] in
            guard actionsAllowed(), let (pid, window) = resolveFocusedWindow(), !isIgnored(pid: pid),
                  let id = idByRef[window], let state = lastStates[id], state == .tiled || state == .floating,
                  let frame = lastTargets[id] ?? (try? deps.ax.frame(of: window)) else { return }
            let displays = deps.displays.displays().sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            guard displays.count > 1, let current = deps.displays.display(for: frame),
                  let at = displays.firstIndex(where: { $0.id == current.id }) else { return }
            let target = displays[(at + (next ? 1 : displays.count - 1)) % displays.count]
            activity += 1
            var landed: CGRect?
            if state == .tiled, let space = engineSpace(of: target),
               let moved = try? engine.moveToSpace(window: id, target: space) {
                apply(moved.target)
                apply(moved.source)
                landed = lastTargets[id]
            } else {
                // Floating, or a display the engine hasn't seen yet: place the window and let the reconcile adopt it.
                var size = frame.size
                size.width = min(size.width, target.visibleFrame.width); size.height = min(size.height, target.visibleFrame.height)
                let f = CGRect(x: target.visibleFrame.midX - size.width / 2, y: target.visibleFrame.midY - size.height / 2,
                               width: size.width, height: size.height)
                if state == .floating { firstSeenFrame[id] = f }
                executor.place(window, frame: f)
                landed = f
                scheduleReconcile(after: 0.05)
            }
            if let landed { deps.poster.post(.warpCursor(CGPoint(x: landed.midX, y: landed.midY))) }
            EventLog.shared.emit("move_display", ["window": Int(window.windowID), "display": Int(target.id), "next": next])
        }
    }

    // MARK: helpers (on `queue`)

    private func actionsAllowed() -> Bool {
        running && !userPaused && !stageManagerPaused && !dragging && !throwInFlight
    }

    private func focusedTiled() -> (window: HyprPlatform.WindowRef, id: UInt64, space: UInt64)? {
        guard actionsAllowed(), let (pid, window) = resolveFocusedWindow(), !isIgnored(pid: pid),
              let id = idByRef[window], lastStates[id] == .tiled, let space = engine.space(of: id) else { return nil }
        return (window, id, space)
    }

    /// The engine's id for `display`'s active Space (mirrors the synthetic ids of `reconcileNow` when
    /// "Displays have separate Spaces" is off and every display reports the same Space).
    private func engineSpace(of display: DisplayInfo) -> UInt64? {
        let all = deps.displays.displays()
        let native = deps.spaces.activeSpace(display: display.id)
        let shared = all.filter { deps.spaces.activeSpace(display: $0.id) == native }.count > 1
        let id = shared ? Self.perDisplaySpaceID(space: native, display: display.id) : native
        return activeSpaces.contains(id) ? id : nil
    }
}
