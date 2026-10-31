import CoreGraphics
import Foundation

/// Recognises moved/resized notifications caused by our own writes.
///
/// The executor records every frame it expects a window to pass through; an observed frame
/// within `tolerance` points of a record younger than `window` seconds is an echo. Thread-safe.
public final class EchoFilter: @unchecked Sendable {
    public let window: TimeInterval
    public let tolerance: CGFloat
    private let lock = NSLock()
    private var records: [WindowRef: [(frame: CGRect, at: TimeInterval)]] = [:]

    public init(window: TimeInterval = 1.0, tolerance: CGFloat = 2) {
        self.window = window
        self.tolerance = tolerance
    }

    public func record(_ ref: WindowRef, frame: CGRect, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        var list = records[ref, default: []].filter { now - $0.at <= window }
        list.append((frame, now))
        records[ref] = list
    }

    public func isEcho(_ ref: WindowRef, observedFrame: CGRect, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records[ref, default: []].contains {
            now - $0.at <= window && now >= $0.at - window && $0.frame.isApproximately(observedFrame, tolerance: tolerance)
        }
    }

    public func forget(_ ref: WindowRef) {
        lock.lock(); records[ref] = nil; lock.unlock()
    }

    public func forget(pid: pid_t) {
        lock.lock(); records = records.filter { $0.key.pid != pid }; lock.unlock()
    }
}
