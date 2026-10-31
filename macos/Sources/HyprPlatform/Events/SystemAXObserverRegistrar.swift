import ApplicationServices
import Foundation

/// Real AX observer registration. All observers live on one dedicated run-loop thread, shared
/// process-wide (`shared`), so restarting `PlatformEvents` never leaks a thread.
///
/// Lifetime: each `Registration` is handed to C as a **retained** refcon. `unregister` performs
/// its teardown (remove source and notifications, release the refcon) *on the observer thread*,
/// so it is serialised with callbacks and a callback can never see a freed registration.
///
/// `register` does blocking AX IPC to the target app; call it off the main thread (the hub runs
/// it on its scheduler queue). The app element gets a short messaging timeout first.
public final class SystemAXObserverRegistrar: AXObserverRegistrar, @unchecked Sendable {
    /// The process-wide registrar (one observer thread for the whole app).
    public static let shared = SystemAXObserverRegistrar()
    /// Messaging timeout set on each app element before `AXObserverAddNotification`.
    public static let registrationTimeout: Float = 0.25

    /// One registered app.
    final class Registration {
        let pid: pid_t
        let observer: AXObserver
        let app: AXUIElement
        let sink: (PlatformEvent) -> Void
        let lock = NSLock()
        /// Window element → ref, so `AXUIElementDestroyed` can still be attributed.
        var known: [ElementKey: WindowRef] = [:]
        /// Retained `Unmanaged` pointer to self, released on the observer thread at teardown.
        var refcon: UnsafeMutableRawPointer?

        init(pid: pid_t, observer: AXObserver, app: AXUIElement, sink: @escaping (PlatformEvent) -> Void) {
            self.pid = pid
            self.observer = observer
            self.app = app
            self.sink = sink
        }

        /// Adds the window-level notifications (repeat calls return `notificationAlreadyRegistered`).
        func watchWindow(_ el: AXUIElement) -> WindowRef? {
            let ref = PrivateAPI.windowID(of: el).map { WindowRef(pid: pid, windowID: $0) }
            for n in AXNotificationName.windowLevel {
                AXObserverAddNotification(observer, el, n as CFString, refcon)
            }
            lock.lock(); if let r = ref { known[ElementKey(el)] = r }; lock.unlock()
            return ref
        }

        func handle(_ el: AXUIElement, _ name: String) {
            var ref: WindowRef?
            switch name {
            case AXNotificationName.windowCreated:
                ref = watchWindow(el)
            case AXNotificationName.uiElementDestroyed:
                lock.lock(); ref = known.removeValue(forKey: ElementKey(el)); lock.unlock()
            case AXNotificationName.applicationHidden, AXNotificationName.applicationShown,
                 AXNotificationName.applicationActivated:
                ref = nil
            default:
                var target = el
                if name == AXNotificationName.focusedWindowChanged || name == AXNotificationName.mainWindowChanged {
                    // Delivered on the window for most apps; on the app for some.
                    var role: CFTypeRef?
                    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                    if (role as? String) == (kAXApplicationRole as String) {
                        var w: CFTypeRef?
                        let attr = name == AXNotificationName.mainWindowChanged ? kAXMainWindowAttribute : kAXFocusedWindowAttribute
                        if AXUIElementCopyAttributeValue(el, attr as CFString, &w) == .success, let w,
                           CFGetTypeID(w) == AXUIElementGetTypeID() {
                            target = w as! AXUIElement
                        }
                    }
                }
                ref = PrivateAPI.windowID(of: target).map { WindowRef(pid: pid, windowID: $0) }
            }
            if let e = AXNotificationName.event(for: name, pid: pid, window: ref) { sink(e) }
        }
    }

    /// Hashable wrapper using `CFEqual`/`CFHash`.
    struct ElementKey: Hashable {
        let element: AXUIElement
        init(_ e: AXUIElement) { element = e }
        static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
        func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
    }

    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    /// Prefer `shared`; a new instance starts its own observer thread.
    public init() {
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            self?.ready.signal()
            // Keep the run loop alive with a dummy port-less timer source.
            let timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "hyprmac.ax-observers"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    public func register(pid: pid_t, sink: @escaping (PlatformEvent) -> Void) throws -> AnyObject {
        if Thread.isMainThread { Log.events.fault("AX observer registration on the main thread (pid \(pid))") }
        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, element, name, refcon in
            guard let refcon else { return }
            // Retained until teardown, which runs on this same thread.
            let reg = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
            reg.handle(element, name as String)
        }, &obs)
        guard err == .success, let observer = obs else { throw AXBackendError(err) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.registrationTimeout)
        let reg = Registration(pid: pid, observer: observer, app: app, sink: sink)
        let refcon = Unmanaged.passRetained(reg).toOpaque()
        reg.refcon = refcon
        for n in AXNotificationName.appLevel {
            let e = AXObserverAddNotification(observer, app, n as CFString, refcon)
            // The first one failing means the app isn't ready (or hung): stop messaging it and
            // let the hub retry. No source was added yet, so no callback can hold the refcon.
            if e != .success && e != .notificationAlreadyRegistered && n == AXNotificationName.windowCreated {
                Unmanaged<Registration>.fromOpaque(refcon).release()
                throw AXBackendError(e)
            }
        }
        watchCurrentWindows(reg)
        if let rl = runLoop {
            CFRunLoopAddSource(rl, AXObserverGetRunLoopSource(observer), .defaultMode)
            CFRunLoopWakeUp(rl)
        }
        return reg
    }

    /// Re-adds `AXUIElementDestroyed` for every window `kAXWindows` lists now. `kAXWindows` only
    /// lists windows on the current Space, so call this after Space changes.
    public func rewatch(_ token: AnyObject) {
        guard let reg = token as? Registration else { return }
        watchCurrentWindows(reg)
    }

    private func watchCurrentWindows(_ reg: Registration) {
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(reg.app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AnyObject] else { return }
        for w in list where CFGetTypeID(w as CFTypeRef) == AXUIElementGetTypeID() {
            _ = reg.watchWindow(w as! AXUIElement) // type-checked above
        }
    }

    public func unregister(_ token: AnyObject) {
        guard let reg = token as? Registration, let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(reg.observer), .defaultMode)
            for n in AXNotificationName.appLevel {
                AXObserverRemoveNotification(reg.observer, reg.app, n as CFString)
            }
            reg.lock.lock()
            let windows = reg.known.keys.map(\.element)
            reg.known.removeAll()
            reg.lock.unlock()
            for w in windows {
                for n in AXNotificationName.windowLevel { AXObserverRemoveNotification(reg.observer, w, n as CFString) }
            }
            if let refcon = reg.refcon {
                reg.refcon = nil
                Unmanaged<Registration>.fromOpaque(refcon).release()
            }
        }
        CFRunLoopWakeUp(rl)
    }
}
