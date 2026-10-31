import CoreGraphics
import Foundation
import HyprPlatform

/// ⌥⇧F: toggle the focused window between floating and tiled.
///
/// The choice is an explicit per-window override (`floatOverride`, true = floating) that beats every
/// automatic floating decision (fight-floating, rule-based and size-based floating). The one thing it
/// never overrides is the platform's eligibility float list (non-resizable windows, float bundle ids).
/// It is sticky until toggled again or the window closes, and is dropped with the window's engine
/// state (`forgetEngineWindow`: close, app termination).
extension Coordinator {

    /// Hotkey entry point (any thread).
    func toggleFocusedFloat() {
        queue.async { [self] in toggleFocusedFloatNow() }
    }

    /// On `queue`. Internal for tests.
    func toggleFocusedFloatNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, !userPaused, !stageManagerPaused, !dragging, !throwInFlight else { return }
        guard let pid = try? deps.ax.focusedApplication(), let window = try? deps.ax.focusedWindow(pid: pid),
              !isIgnored(pid: pid), let id = idByRef[window], let state = lastStates[id] else { return }
        // Fullscreen / minimized / hidden windows are left alone (checked live too: the cached
        // state may predate the change).
        if (try? deps.ax.bool(.fullscreen, of: window)) == true || (try? deps.ax.bool(.minimized, of: window)) == true {
            return
        }
        activity += 1
        switch state {
        case .tiled:
            floatOverride[id] = true
            let frame = restoreFrame(for: window, id: id)
            reconcileNow() // the window leaves the tree; its neighbours reflow
            if let frame { executor.place(window, frame: frame) }
            EventLog.shared.emit("toggle_float", ["window": Int(window.windowID), "state": "floating"])
        case .floating:
            guard !platformFloating.contains(id) else { return } // eligibility floats stay floating
            floatOverride[id] = false
            uncooperative.remove(id)
            fights[id] = nil
            reconcileNow() // dwindle insertion
            EventLog.shared.emit("toggle_float", ["window": Int(window.windowID), "state": "tiled"])
        case .minimized, .fullscreen, .hidden:
            return
        }
    }

    /// Applies the override to the state computed for a window during reconcile, and records the
    /// first-seen frame. `platform` is the eligibility result, `current` the state after the
    /// automatic (fight / rule / size) decisions.
    func resolveFloatOverride(id: UInt64, platform: WindowState, frame: CGRect,
                              current: Engine.TileState) -> Engine.TileState {
        if platform == .tiled || platform == .floating {
            if firstSeenFrame[id] == nil, frame.width > 0, frame.height > 0, Self.sanitized(frame) != .zero {
                firstSeenFrame[id] = frame
            }
            if platform == .floating { platformFloating.insert(id) } else { platformFloating.remove(id) }
        }
        guard let wantFloat = floatOverride[id], platform == .tiled,
              current == .tiled || current == .floating else { return current }
        if wantFloat { return .floating }
        // Forced into the tree but it keeps fighting its tile again: give up rather than loop.
        if uncooperative.contains(id) {
            floatOverride[id] = nil
            EventLog.shared.emit("toggle_float", ["window": Int(id), "state": "floating", "reason": "fights"])
            return .floating
        }
        return .tiled
    }

    /// The state the engine sees. A window the USER floated with ⌥⇧F is reported `.hidden`, which the
    /// engine treats as a ghost: the tree closes over it but remembers its slot (sibling, orientation,
    /// ratio), so toggling back restores the same position instead of dwindle-inserting it (which swapped
    /// it with its sibling, verified by the toggle-float E2E). The coordinator keeps `.floating` in
    /// `lastStates`; automatic floats (small, rules, fights) stay `.floating`, i.e. no slot is kept.
    func engineState(id: UInt64, state: Engine.TileState, platform: WindowState) -> Engine.TileState {
        state == .floating && floatOverride[id] == true && platform == .tiled ? .hidden : state
    }

    func forgetToggleState(_ id: UInt64) {
        floatOverride[id] = nil
        firstSeenFrame[id] = nil
        platformFloating.remove(id)
    }

    /// The window's first-seen size, centred on its display's usable rect and clamped inside it.
    private func restoreFrame(for window: HyprPlatform.WindowRef, id: UInt64) -> CGRect? {
        guard let original = firstSeenFrame[id] else { return nil }
        let current = try? deps.ax.frame(of: window)
        let displays = deps.displays.displays()
        let display = current.flatMap { deps.displays.display(for: $0) }
            ?? displays.first(where: { $0.isMain }) ?? displays.first
        guard let usable = display?.visibleFrame, usable.width > 0, usable.height > 0 else { return nil }
        let w = min(original.width, usable.width), h = min(original.height, usable.height)
        let x = min(max(usable.midX - w / 2, usable.minX), usable.maxX - w)
        let y = min(max(usable.midY - h / 2, usable.minY), usable.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
