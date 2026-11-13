import CoreGraphics
import Foundation
import HyprPlatform

/// EXPERIMENTAL `rules.desktop`: throw a new window of an app to a fixed Desktop with the drag trick.
///
/// A window is a candidate only when ALL hold: its app is in `rules.desktop`; it was not among the
/// windows present when pinning was first evaluated (startup or the reload that enabled it); a
/// window-created event for it (or its app) arrived within `pinFreshness` seconds (so windows of
/// other Spaces that merely become visible later are never moved); it is plain tiled (not
/// fullscreen/minimized/hidden, not floating by rule, title, size or platform); it is not already on
/// Desktop N. Each window is tried at most once: a failure (`noGrabPoint`, `timedOut`, …) is logged and
/// never retried. While a Space transition animates, the attempt is postponed to the next reconcile
/// (it is not counted as a try).
extension Coordinator {
    static let pinFreshness: TimeInterval = 5

    /// Window-created / app-launched bookkeeping. On `queue`.
    func notePinFresh(pid: pid_t, window: HyprPlatform.WindowRef?) {
        let now = deps.clock.now()
        if let window { pinFreshRefs[window] = now } else { pinFreshPids[pid] = now }
        if pinFreshRefs.count > 512 { pinFreshRefs = pinFreshRefs.filter { now - $1 <= Self.pinFreshness } }
    }

    /// Records the windows that exist when pinning is first evaluated (start, or the reload that
    /// enabled it), before any window is considered. On `queue`.
    func ensurePinBaseline() {
        guard pinBaseline == nil, !currentConfig.rules.desktop.isEmpty else { return }
        pinBaseline = currentWindowRefs()
    }

    /// Inspects one discovered window during reconcile; may select it as the pending pin. On `queue`.
    func considerPin(ref: HyprPlatform.WindowRef, state: Engine.TileState, platform: WindowState, display: DisplayID) {
        let rules = currentConfig.rules.desktop
        guard !rules.isEmpty else { return }
        guard pinPending == nil, !pinHandled.contains(ref), !(pinBaseline?.contains(ref) ?? true),
              let bundle = bundleID(for: ref), let n = rules[bundle] else { return }
        let now = deps.clock.now()
        let fresh = (pinFreshRefs[ref].map { now - $0 <= Self.pinFreshness } ?? false)
            || (pinFreshPids[ref.pid].map { now - $0 <= Self.pinFreshness } ?? false)
        guard fresh else { return }
        guard state == .tiled, platform == .tiled else { pinHandled.insert(ref); return } // never moved, ever
        guard let target = deps.spaces.userSpace(index: n, display: display) else {
            pinHandled.insert(ref)
            logPin(ref, n, "noSuchSpace")
            return
        }
        if target.id == deps.spaces.activeSpace(display: display) { pinHandled.insert(ref); return }
        if transitions.remaining(now: now) > 0 { return } // postponed, not a try
        pinHandled.insert(ref)
        pinPending = (ref, n)
    }

    /// Starts the selected pin (after the reconcile pass). On `queue`.
    func startPendingPin() {
        guard let (ref, n) = pinPending else { return }
        pinPending = nil
        guard !throwInFlight else { return }
        activity += 1
        throwInFlight = true
        let sourceSpace = idByRef[ref].flatMap { engine.space(of: $0) }
        moverQueue.async { [self] in
            // The window was just tiled: let the executor finish writing its frame before grabbing it.
            _ = executor.waitUntilIdle(timeout: 1.5)
            let result = mover.move(ref, toSpace: n)
            queue.async { [self] in
                activity += 1
                throwInFlight = false
                hoverGate.noteWarp(now: deps.clock.now()) // the mover restores the cursor
                logPin(ref, n, Self.name(result))
                if case .moved = result {
                    reconcileNow()
                    if let src = sourceSpace, let id = idByRef[ref], engine.space(of: id) != src,
                       let plan = try? engine.relayout(space: src) {
                        apply(plan)
                    }
                    notify(.windowThrown(app: appDisplayName(for: ref), fromSpace: nil, toSpace: n))
                }
                scheduleReconcile(after: 0.03)
            }
        }
    }

    private func logPin(_ ref: HyprPlatform.WindowRef, _ n: Int, _ result: String) {
        logger.notice("pin \(ref.description, privacy: .public) to Desktop \(n): \(result, privacy: .public)")
        EventLog.shared.emit("pin", ["window": Int(ref.windowID), "n": n, "result": result])
    }

    /// Every window the AX layer can list right now (current Spaces only).
    private func currentWindowRefs() -> Set<HyprPlatform.WindowRef> {
        var out = Set<HyprPlatform.WindowRef>()
        for app in deps.apps.runningApplications() where app.activationPolicy == .regular {
            for r in (try? deps.ax.windows(pid: app.pid)) ?? [] { out.insert(r) }
        }
        return out
    }
}
