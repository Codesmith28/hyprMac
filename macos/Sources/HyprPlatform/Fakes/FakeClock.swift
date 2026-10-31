import Foundation

/// Manual clock: `sleep` advances time instantly and is logged. Thread-safe.
public final class FakeClock: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    private var log: [TimeInterval] = []

    public init(start: TimeInterval = 1000) { t = start }

    public func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }

    public func sleep(_ seconds: TimeInterval) {
        lock.lock(); log.append(seconds); t += max(0, seconds); lock.unlock()
    }

    public func advance(by seconds: TimeInterval) { lock.lock(); t += seconds; lock.unlock() }

    /// Every `sleep` duration requested so far.
    public var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return log }
}
