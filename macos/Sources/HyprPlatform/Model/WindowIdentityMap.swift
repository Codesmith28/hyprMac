import CoreGraphics
import Foundation

/// Builds engine window ids `(generation << 32) | CGWindowID` (see `hm_window_id`).
///
/// The generation of a `CGWindowID` increases whenever a *different* pid claims it
/// (window id reused after an app relaunch), so the engine never confuses the two.
/// Thread-safe.
public final class WindowIdentityMap: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: [CGWindowID: (pid: pid_t, gen: UInt32)] = [:]
    private var reverse: [UInt64: WindowRef] = [:]

    public init() {}

    public func engineID(for ref: WindowRef) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        var gen: UInt32 = 0
        if let cur = generation[ref.windowID] {
            gen = cur.pid == ref.pid ? cur.gen : cur.gen &+ 1
        }
        generation[ref.windowID] = (ref.pid, gen)
        let id = (UInt64(gen) << 32) | UInt64(ref.windowID)
        reverse[id] = ref
        return id
    }

    public func ref(forEngineID id: UInt64) -> WindowRef? {
        lock.lock(); defer { lock.unlock() }
        return reverse[id]
    }

    /// Drop the reverse mapping (the generation counter is kept so ids are never reused).
    public func forget(engineID id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        reverse[id] = nil
    }
}
