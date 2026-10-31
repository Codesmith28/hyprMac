import CoreGraphics
import Foundation

/// Outcome reports from the executor.
public enum ExecutorEvent: Equatable, Sendable {
    /// The window landed on the target (within 1 pt). `skipped` = it was already there.
    case landed(WindowRef, revision: UInt64, frame: CGRect, skipped: Bool)
    /// The read-back is larger than the target by more than 1 pt. Dimensions that did NOT
    /// exceed the target are reported as 0 ("unknown"), matching `hm_engine_report_min_size`.
    case minSizeDiscovered(WindowRef, CGSize)
    /// The read-back differs from the target for another reason (app snapped back, clamped, ...).
    case mismatch(WindowRef, target: CGRect, actual: CGRect)
    /// `invalidUIElement`: the window closed.
    case windowGone(WindowRef)
    /// Retries exhausted or a non-retryable AX error.
    case failed(WindowRef, AXBackendError)
}

public protocol GeometryExecutorDelegate: AnyObject {
    func geometryExecutor(_ executor: GeometryExecutor, didReport event: ExecutorEvent)
}

/// Applies geometry plans to windows.
///
/// - One serial queue per pid: a hung app never blocks other apps or the caller.
/// - Latest-wins per window: a newer target replaces an older one that hasn't started.
/// - Stale rejection: targets older than the newest revision seen for a window are dropped.
/// - Per window: messaging timeout → skip if already there (±0.5) → disable
///   `AXEnhancedUserInterface` if on → size → position → size → restore → read back.
public final class GeometryExecutor: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var messagingTimeout: Float = 0.25
        public var skipTolerance: CGFloat = 0.5
        public var landTolerance: CGFloat = 1
        /// Delays before re-running a window whose AX calls failed with `cannotComplete`.
        /// Attempts = `retryDelays.count + 1`.
        public var retryDelays: [TimeInterval] = [0.05, 0.15]
        public init() {}
    }

    private struct Target {
        var revision: UInt64
        var frame: CGRect
        var attempt: Int
    }

    public weak var delegate: GeometryExecutorDelegate?
    public let echo: EchoFilter
    public let configuration: Configuration

    private let ax: AXBackend
    private let clock: TimeSource
    private let delegateQueue: DispatchQueue
    private let lock = NSLock()
    private var newest: [WindowRef: UInt64] = [:]
    private var pending: [WindowRef: Target] = [:]
    private var scheduled = Set<WindowRef>()
    private var queues: [pid_t: DispatchQueue] = [:]
    private let group = DispatchGroup()
    private var stats = Stats()

    /// Counters, mostly for tests and diagnostics.
    public struct Stats: Equatable, Sendable {
        public var staleDropped = 0
        public var coalesced = 0
        public var writesStarted = 0
    }

    public init(ax: AXBackend, echo: EchoFilter = EchoFilter(), clock: TimeSource = SystemTimeSource(),
                configuration: Configuration = Configuration(),
                delegateQueue: DispatchQueue = DispatchQueue(label: "dev.codesmith28.hyprmac.executor.delegate")) {
        self.ax = ax
        self.echo = echo
        self.clock = clock
        self.configuration = configuration
        self.delegateQueue = delegateQueue
    }

    public var statistics: Stats { lock.lock(); defer { lock.unlock() }; return stats }

    /// Queue a plan. Returns immediately.
    public func apply(revision: UInt64, placements: [(WindowRef, CGRect)]) {
        lock.lock(); defer { lock.unlock() }
        for (ref, frame) in placements {
            if let n = newest[ref], revision < n {
                stats.staleDropped += 1
                continue
            }
            newest[ref] = revision
            if pending[ref] != nil { stats.coalesced += 1 }
            pending[ref] = Target(revision: revision, frame: frame, attempt: 0)
            scheduleLocked(ref, after: 0)
        }
    }

    /// Drop all state for a window (closed) or app (terminated).
    public func forget(_ ref: WindowRef) {
        lock.lock(); newest[ref] = nil; pending[ref] = nil; lock.unlock()
        echo.forget(ref)
    }

    public func forget(pid: pid_t) {
        lock.lock()
        newest = newest.filter { $0.key.pid != pid }
        pending = pending.filter { $0.key.pid != pid }
        lock.unlock()
        echo.forget(pid: pid)
    }

    /// Blocks until all queued work (including retries) finished and reports were delivered.
    /// Never call it on the delegate queue.
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 5) -> Bool {
        guard group.wait(timeout: .now() + timeout) == .success else { return false }
        delegateQueue.sync {}
        return true
    }

    // MARK: - scheduling

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "dev.codesmith28.hyprmac.executor.\(pid)")
        queues[pid] = q
        return q
    }

    /// Caller holds `lock`.
    private func scheduleLocked(_ ref: WindowRef, after delay: TimeInterval) {
        guard !scheduled.contains(ref) else { return }
        scheduled.insert(ref)
        group.enter()
        let q = queue(for: ref.pid)
        let work = { [self] in run(ref); group.leave() }
        if delay > 0 { q.asyncAfter(deadline: .now() + delay, execute: work) } else { q.async(execute: work) }
    }

    private func run(_ ref: WindowRef) {
        lock.lock()
        scheduled.remove(ref)
        guard let target = pending.removeValue(forKey: ref) else { lock.unlock(); return }
        stats.writesStarted += 1
        lock.unlock()

        do {
            if let event = try perform(ref, target) { report(event) }
        } catch let error as AXBackendError {
            handle(error, ref: ref, target: target)
        } catch {
            report(.failed(ref, .other(-1)))
        }
    }

    private func handle(_ error: AXBackendError, ref: WindowRef, target: Target) {
        switch error {
        case .invalidUIElement:
            forget(ref)
            report(.windowGone(ref))
        case .cannotComplete:
            lock.lock()
            defer { lock.unlock() }
            guard pending[ref] == nil else { return } // a newer target supersedes this one
            guard target.attempt < configuration.retryDelays.count else {
                report(.failed(ref, error))
                return
            }
            var next = target
            next.attempt += 1
            pending[ref] = next
            scheduleLocked(ref, after: configuration.retryDelays[target.attempt])
        default:
            report(.failed(ref, error))
        }
    }

    // MARK: - the write

    private func perform(_ ref: WindowRef, _ target: Target) throws -> ExecutorEvent? {
        let goal = target.frame
        ax.setMessagingTimeout(pid: ref.pid, seconds: configuration.messagingTimeout)
        let current = try ax.frame(of: ref)
        if current.isApproximately(goal, tolerance: configuration.skipTolerance) {
            return .landed(ref, revision: target.revision, frame: current, skipped: true)
        }
        let now = clock.now()
        echo.record(ref, frame: goal, at: now)
        echo.record(ref, frame: CGRect(origin: current.origin, size: goal.size), at: now)
        echo.record(ref, frame: CGRect(origin: goal.origin, size: current.size), at: now)

        let enhanced = (try? ax.enhancedUserInterface(pid: ref.pid)) ?? false
        if enhanced { try? ax.setEnhancedUserInterface(false, pid: ref.pid) }
        var restored = !enhanced
        defer { if !restored { try? ax.setEnhancedUserInterface(true, pid: ref.pid) } }

        try ax.setSize(goal.size, of: ref)
        try ax.setPosition(goal.origin, of: ref)
        try ax.setSize(goal.size, of: ref)
        if enhanced {
            try? ax.setEnhancedUserInterface(true, pid: ref.pid)
            restored = true
        }

        let actual = try ax.frame(of: ref)
        echo.record(ref, frame: actual, at: clock.now())
        let tol = configuration.landTolerance
        if actual.width > goal.width + tol || actual.height > goal.height + tol {
            return .minSizeDiscovered(ref, CGSize(width: actual.width > goal.width + tol ? actual.width : 0,
                                                  height: actual.height > goal.height + tol ? actual.height : 0))
        }
        if !actual.isApproximately(goal, tolerance: tol) {
            return .mismatch(ref, target: goal, actual: actual)
        }
        return .landed(ref, revision: target.revision, frame: actual, skipped: false)
    }

    private func report(_ event: ExecutorEvent) {
        group.enter()
        delegateQueue.async { [self] in
            delegate?.geometryExecutor(self, didReport: event)
            group.leave()
        }
    }
}
