import Foundation

/// Tracks in-flight Space transitions.
///
/// Verified on macOS 27.2: a ⌥N posted while a Space transition animation is still running is
/// **silently dropped**. Callers note every switch they issue or observe, and don't issue
/// another switch until `canSwitch(now:)` is true. Thread-safe.
public final class SpaceTransitionGuard: @unchecked Sendable {
    /// How long after a switch the animation is assumed to still be running.
    public let settle: TimeInterval
    private let lock = NSLock()
    private var lastSwitch: TimeInterval?

    public init(settle: TimeInterval = 0.5) { self.settle = settle }

    /// Record that a transition started (or was observed) at `now`.
    public func noteTransition(at now: TimeInterval) {
        lock.lock(); lastSwitch = now; lock.unlock()
    }

    public func canSwitch(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastSwitch else { return true }
        return now - last >= settle
    }

    /// Seconds until a switch is allowed (0 when allowed now).
    public func remaining(now: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastSwitch else { return 0 }
        return max(0, settle - (now - last))
    }
}
