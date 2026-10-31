import Foundation

/// Retry schedule for AX observer registration at app launch (apps often aren't ready).
public enum ObserverRetrySchedule {
    public static let delays: [TimeInterval] = [0.05, 0.15, 0.4, 1.0]
}

/// Registers AX observers for one app. The real one is `SystemAXObserverRegistrar`.
public protocol AXObserverRegistrar: AnyObject {
    /// Start observing `pid`; notifications go to `sink` (any thread). Throws (typically
    /// `AXBackendError.cannotComplete`) when the app isn't ready yet.
    func register(pid: pid_t, sink: @escaping (PlatformEvent) -> Void) throws -> AnyObject
    func unregister(_ token: AnyObject)
}

/// Delayed execution, injectable for tests.
public protocol DelayScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

public final class DispatchDelayScheduler: DelayScheduler {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue = DispatchQueue(label: "dev.codesmith28.hyprmac.observer.retry")) { self.queue = queue }
    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Keeps one AX observer registration per app, retrying failed registrations with
/// `ObserverRetrySchedule.delays` (50, 150, 400, 1000 ms) before reporting
/// `.observerRegistrationFailed`. Thread-safe.
public final class AXObserverHub: @unchecked Sendable {
    private let registrar: AXObserverRegistrar
    private let scheduler: DelayScheduler
    private let delays: [TimeInterval]
    private let emit: (PlatformEvent) -> Void
    private let lock = NSLock()
    private var tokens: [pid_t: AnyObject] = [:]
    /// pids we want observed; a retry for a pid no longer wanted is abandoned.
    private var wanted: [pid_t: Int] = [:]
    private var generation = 0

    public init(registrar: AXObserverRegistrar, scheduler: DelayScheduler = DispatchDelayScheduler(),
                delays: [TimeInterval] = ObserverRetrySchedule.delays, emit: @escaping (PlatformEvent) -> Void) {
        self.registrar = registrar
        self.scheduler = scheduler
        self.delays = delays
        self.emit = emit
    }

    public var observedPids: Set<pid_t> { lock.lock(); defer { lock.unlock() }; return Set(tokens.keys) }

    public func observe(pid: pid_t) {
        lock.lock()
        guard tokens[pid] == nil, wanted[pid] == nil else { lock.unlock(); return }
        generation += 1
        wanted[pid] = generation
        let gen = generation
        lock.unlock()
        attempt(pid: pid, gen: gen, index: 0)
    }

    public func stopObserving(pid: pid_t) {
        lock.lock()
        wanted[pid] = nil
        let token = tokens.removeValue(forKey: pid)
        lock.unlock()
        if let t = token { registrar.unregister(t) }
    }

    private func attempt(pid: pid_t, gen: Int, index: Int) {
        lock.lock()
        let stillWanted = wanted[pid] == gen
        lock.unlock()
        guard stillWanted else { return }
        do {
            let token = try registrar.register(pid: pid, sink: emit)
            lock.lock()
            if wanted[pid] == gen {
                tokens[pid] = token
                lock.unlock()
            } else {
                lock.unlock()
                registrar.unregister(token)
            }
        } catch {
            guard index < delays.count else {
                lock.lock(); if wanted[pid] == gen { wanted[pid] = nil }; lock.unlock()
                Log.events.error("AX observer registration failed for pid \(pid): \(String(describing: error))")
                emit(.observerRegistrationFailed(pid))
                return
            }
            scheduler.schedule(after: delays[index]) { [weak self] in
                self?.attempt(pid: pid, gen: gen, index: index + 1)
            }
        }
    }
}
