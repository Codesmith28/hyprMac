import Foundation
import HyprPlatform

/// Pure decision logic of `focus_follows_mouse`; time is passed in (tests use the fake clock).
///
/// - A window is focused only after the cursor has rested on it for `debounce` seconds.
/// - Moves during `warpSuppression` seconds after a programmatic cursor warp (focus_direction,
///   throws, pins: the cursor auto-centres onto the focused window) are ignored, and a candidate
///   pending at warp time is dropped.
/// - The already-focused window is never refocused, and a decision is consumed once taken.
struct HoverFocusGate {
    var debounce: TimeInterval = 0.12
    var warpSuppression: TimeInterval = 0.4

    private(set) var candidate: WindowRef?
    private var since: TimeInterval = 0
    private var suppressedUntil: TimeInterval = -.infinity

    /// Records the window under the cursor (nil = none). Returns true when a new candidate started
    /// resting, i.e. a check should be scheduled `debounce` later.
    @discardableResult
    mutating func noteHover(_ window: WindowRef?, now: TimeInterval) -> Bool {
        if now < suppressedUntil { return false }
        guard window != candidate else { return false }
        candidate = window
        since = now
        return window != nil
    }

    /// The cursor was moved by hyprMac itself.
    mutating func noteWarp(now: TimeInterval) {
        suppressedUntil = max(suppressedUntil, now + warpSuppression)
        candidate = nil
    }

    /// The window to focus now, if any. Consumes the candidate.
    mutating func due(now: TimeInterval, focused: WindowRef?) -> WindowRef? {
        guard let c = candidate else { return nil }
        if now < suppressedUntil { candidate = nil; return nil }
        guard now - since >= debounce - 0.000_001 else { return nil }
        candidate = nil
        return c == focused ? nil : c
    }

    mutating func reset() { candidate = nil }
}
