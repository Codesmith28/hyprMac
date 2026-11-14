import CoreGraphics
import Foundation

/// `AXObserverRegistrar` that fails a configurable number of times per pid.
public final class FakeAXObserverRegistrar: AXObserverRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    /// Failures before a registration succeeds (`Int.max` = always fail).
    public var failuresBeforeSuccess: [pid_t: Int] = [:]
    public private(set) var attempts: [pid_t] = []
    public private(set) var unregistered: [pid_t] = []
    private var sinks: [pid_t: (PlatformEvent) -> Void] = [:]

    final class Token { let pid: pid_t; init(_ p: pid_t) { pid = p } }

    public init() {}

    public func register(pid: pid_t, sink: @escaping (PlatformEvent) -> Void) throws -> AnyObject {
        lock.lock(); defer { lock.unlock() }
        attempts.append(pid)
        let left = failuresBeforeSuccess[pid, default: 0]
        if left > 0 {
            failuresBeforeSuccess[pid] = left == Int.max ? left : left - 1
            throw AXBackendError.cannotComplete
        }
        sinks[pid] = sink
        return Token(pid)
    }

    public func unregister(_ token: AnyObject) {
        guard let t = token as? Token else { return }
        lock.lock(); sinks[t.pid] = nil; unregistered.append(t.pid); lock.unlock()
    }

    public private(set) var rewatched: [pid_t] = []

    public func rewatch(_ token: AnyObject) {
        guard let t = token as? Token else { return }
        lock.lock(); rewatched.append(t.pid); lock.unlock()
    }

    /// Deliver an event as if the observer for `pid` fired. Returns false if not registered.
    @discardableResult
    public func fire(_ event: PlatformEvent, pid: pid_t) -> Bool {
        lock.lock(); let s = sinks[pid]; lock.unlock()
        s?(event)
        return s != nil
    }
}

/// `DelayScheduler` that records delays and runs work only when told.
public final class FakeDelayScheduler: DelayScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(TimeInterval, () -> Void)] = []
    public private(set) var requestedDelays: [TimeInterval] = []
    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        lock.lock(); requestedDelays.append(delay); queue.append((delay, work)); lock.unlock()
    }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return queue.count }

    /// Runs only the oldest scheduled work item. Returns false if nothing was pending.
    @discardableResult
    public func runNext() -> Bool {
        lock.lock()
        guard !queue.isEmpty else { lock.unlock(); return false }
        let (_, work) = queue.removeFirst()
        lock.unlock()
        work()
        return true
    }

    /// Runs scheduled work (including work scheduled while running) until none is left.
    public func runAll() {
        while true {
            lock.lock()
            guard !queue.isEmpty else { lock.unlock(); return }
            let (_, work) = queue.removeFirst()
            lock.unlock()
            work()
        }
    }
}

public final class FakeMouseMonitor: MouseMonitoring {
    private var handler: ((PlatformEvent) -> Void)?
    public init() {}
    public func start(_ handler: @escaping (PlatformEvent) -> Void) { self.handler = handler }
    public func stop() { handler = nil }
    public var isRunning: Bool { handler != nil }
    public func simulate(_ event: PlatformEvent) { handler?(event) }
}

public final class FakeThrowHotkeys: ThrowHotkeys {
    private var onThrow: ((Int) -> Void)?
    public var failingDigits: [Int] = []
    public var onToggleFloat: (() -> Void)?
    public var onCenterWindow: (() -> Void)?
    public var onFocusDirection: ((Direction) -> Void)?
    public var onMoveDirection: ((Direction) -> Void)?
    public var onAction: ((KeyAction) -> Void)?
    public var toggleFloatFailed = false
    /// The bindings of the last `start` (nil while stopped).
    public private(set) var bindings: KeyBindings?
    /// How many times `start` ran (a reload registers again).
    public private(set) var startCount = 0
    public init() {}
    /// What the real `HotkeyCenter` would have registered for the current bindings.
    public var registrations: [(id: UInt32, keyCode: UInt32, modifiers: UInt32)] {
        bindings.map { HotkeyCenter.registrations(for: $0) } ?? []
    }
    @discardableResult
    public func start(bindings: KeyBindings, onThrow: @escaping (Int) -> Void) -> [Int] {
        self.bindings = bindings; startCount += 1; self.onThrow = onThrow; return failingDigits
    }
    public func stop() { onThrow = nil; bindings = nil }
    public func press(_ n: Int) { onThrow?(n) }
    /// Simulates ⌥⇧F.
    public func pressToggleFloat() { onToggleFloat?() }
    public func pressCenterWindow() { onCenterWindow?() }
    public func pressFocus(_ direction: Direction) { onFocusDirection?(direction) }
    public func pressMove(_ direction: Direction) { onMoveDirection?(direction) }
    public func pressAction(_ action: KeyAction) { onAction?(action) }
}

public final class FakeSpaceKeyObserver: SpaceKeyObserving {
    private var onSwitch: ((Int) -> Void)?
    public var permitted = true
    /// The modifiers of the last `start` (what the tap filters for).
    public private(set) var modifiers: CGEventFlags = .maskAlternate
    public private(set) var startCount = 0
    public init() {}
    @discardableResult
    public func start(modifiers: CGEventFlags, onSwitch: @escaping (Int) -> Void) -> Bool {
        startCount += 1
        guard permitted else { return false }
        self.modifiers = modifiers
        self.onSwitch = onSwitch
        return true
    }
    public func stop() { onSwitch = nil }
    /// Feeds a raw key through the real filter.
    public func key(_ code: CGKeyCode, flags: CGEventFlags, isAutorepeat: Bool = false, userData: Int64 = 0) {
        if let n = SpaceKeyFilter.digit(keyCode: code, flags: flags, modifiers: modifiers, isAutorepeat: isAutorepeat,
                                       sourceUserData: userData) {
            onSwitch?(n)
        }
    }
}
