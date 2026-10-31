import AppKit
import Foundation

/// Global left-mouse monitor. Synthetic events (ours) are ignored.
public protocol MouseMonitoring: AnyObject {
    func start(_ handler: @escaping (PlatformEvent) -> Void)
    func stop()
}

public final class SystemMouseMonitor: MouseMonitoring {
    private var monitor: Any?
    public init() {}

    /// Must be called on the main thread.
    public func start(_ handler: @escaping (PlatformEvent) -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            guard !SyntheticEventMarker.isSynthetic(userData: userData) else { return }
            let p = event.cgEvent?.location ?? .zero // top-left global
            handler(event.type == .leftMouseDown ? .userDragBegan(p) : .userDragEnded(p))
        }
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Source of every `PlatformEvent`: AX observers (via `AXObserverHub`), NSWorkspace
/// notifications, screen-parameter changes and the mouse monitor. Events are delivered
/// through one callback on the caller's queue.
public final class PlatformEvents {
    private let queue: DispatchQueue
    private let handler: (PlatformEvent) -> Void
    private let apps: AppProvider
    private let mouse: MouseMonitoring
    private let ownBundleID: String?
    private var tokens: [NSObjectProtocol] = []
    public private(set) var hub: AXObserverHub!

    public init(queue: DispatchQueue, registrar: AXObserverRegistrar = SystemAXObserverRegistrar.shared,
                scheduler: DelayScheduler = DispatchDelayScheduler(),
                apps: AppProvider = SystemAppProvider(), mouse: MouseMonitoring = SystemMouseMonitor(),
                ownBundleID: String? = WindowEligibility.ownBundleID,
                handler: @escaping (PlatformEvent) -> Void) {
        self.queue = queue
        self.handler = handler
        self.apps = apps
        self.mouse = mouse
        self.ownBundleID = ownBundleID
        self.hub = AXObserverHub(registrar: registrar, scheduler: scheduler) { [weak self] e in self?.deliver(e) }
    }

    private func deliver(_ event: PlatformEvent) {
        queue.async { [handler] in handler(event) }
    }

    private func shouldObserve(_ app: AppInfo) -> Bool {
        app.activationPolicy == .regular && (ownBundleID == nil || app.bundleID != ownBundleID)
    }

    /// Call on the main thread.
    public func start() {
        for app in apps.runningApplications() where shouldObserve(app) { hub.observe(pid: app.pid) }

        let ws = NSWorkspace.shared.notificationCenter
        func pid(_ n: Notification) -> pid_t? {
            (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        tokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let info = SystemAppProvider.info(app) else { return }
            if self.shouldObserve(info) { self.hub.observe(pid: info.pid) }
            self.deliver(.appLaunched(info.pid, bundleID: info.bundleID))
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] n in
            guard let self, let p = pid(n) else { return }
            self.hub.stopObserving(pid: p)
            self.deliver(.appTerminated(p))
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: nil) { [weak self] n in
            if let p = pid(n) { self?.deliver(.appHidden(p)) }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: nil) { [weak self] n in
            if let p = pid(n) { self?.deliver(.appShown(p)) }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] n in
            if let p = pid(n) { self?.deliver(.appActivated(p)) }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.hub.rewatchAll() // windows on the new Space weren't listed at registration
            self?.deliver(.activeSpaceChanged)
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            self?.deliver(.screenParametersChanged)
        })
        mouse.start { [weak self] e in self?.deliver(e) }
    }

    public func stop() {
        for t in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
            NotificationCenter.default.removeObserver(t)
        }
        tokens.removeAll()
        mouse.stop()
        for p in hub.observedPids { hub.stopObserving(pid: p) }
    }
}
