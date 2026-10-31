import Foundation

/// Monotonic time plus sleeping, injectable for tests (`FakeClock`).
public protocol TimeSource: AnyObject {
    /// Monotonic seconds.
    func now() -> TimeInterval
    /// Block the calling thread.
    func sleep(_ seconds: TimeInterval)
}

public final class SystemTimeSource: TimeSource, @unchecked Sendable {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: TimeInterval) { if seconds > 0 { Thread.sleep(forTimeInterval: seconds) } }
}
