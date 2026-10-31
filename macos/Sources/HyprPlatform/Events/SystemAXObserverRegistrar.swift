import ApplicationServices
import Foundation

/// Real AX observer registration. All observers live on one dedicated run-loop thread.
public final class SystemAXObserverRegistrar: AXObserverRegistrar, @unchecked Sendable {
    /// One registered app.
    final class Registration {
        let pid: pid_t
        let observer: AXObserver
        let app: AXUIElement
        let sink: (PlatformEvent) -> Void
        let lock = NSLock()
        /// Window element → ref, so `AXUIElementDestroyed` can still be attributed.
        var known: [ElementKey: WindowRef] = [:]

        init(pid: pid_t, observer: AXObserver, app: AXUIElement, sink: @escaping (PlatformEvent) -> Void) {
            self.pid = pid
            self.observer = observer
            self.app = app
            self.sink = sink
        }

        func watchWindow(_ el: AXUIElement) -> WindowRef? {
            let ref = PrivateAPI.windowID(of: el).map { WindowRef(pid: pid, windowID: $0) }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
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
        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, element, name, refcon in
            guard let refcon else { return }
            let reg = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
            reg.handle(element, name as String)
        }, &obs)
        guard err == .success, let observer = obs else { throw AXBackendError(err) }
        let app = AXUIElementCreateApplication(pid)
        let reg = Registration(pid: pid, observer: observer, app: app, sink: sink)
        let refcon = Unmanaged.passUnretained(reg).toOpaque()
        for n in AXNotificationName.appLevel {
            let e = AXObserverAddNotification(observer, app, n as CFString, refcon)
            // The first one failing means the app isn't ready: let the hub retry.
            if e != .success && e != .notificationAlreadyRegistered && n == AXNotificationName.windowCreated {
                throw AXBackendError(e)
            }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            for w in list { _ = reg.watchWindow(w) }
        }
        if let rl = runLoop {
            CFRunLoopAddSource(rl, AXObserverGetRunLoopSource(observer), .defaultMode)
            CFRunLoopWakeUp(rl)
        }
        return reg
    }

    public func unregister(_ token: AnyObject) {
        guard let reg = token as? Registration, let rl = runLoop else { return }
        CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(reg.observer), .defaultMode)
    }
}
