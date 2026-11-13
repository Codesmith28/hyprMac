import AppKit
import CoreGraphics
import Foundation

/// Reports the cursor position (top-left global points) as it moves. Used by `focus_follows_mouse`.
/// `start`/`stop` and the handler run on the main thread.
public protocol MouseMoveMonitoring: AnyObject {
    /// Returns false when the monitor could not be installed.
    func start(_ handler: @escaping (CGPoint) -> Void) -> Bool
    func stop()
}

/// A global `mouseMoved` monitor, throttled to at most one callback per `minInterval` seconds.
/// Reading mouse-move events needs no permission beyond the Accessibility access hyprMac already has.
public final class SystemMouseMoveMonitor: MouseMoveMonitoring {
    private var monitor: Any?
    private var last: TimeInterval = 0
    public let minInterval: TimeInterval

    public init(minInterval: TimeInterval = 0.03) { self.minInterval = minInterval }

    public func start(_ handler: @escaping (CGPoint) -> Void) -> Bool {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.last >= self.minInterval else { return }
            self.last = now
            if let p = CGEvent(source: nil)?.location { handler(p) } // top-left global points
        }
        return monitor != nil
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Test double: `move(to:)` plays a mouse-moved event.
public final class FakeMouseMoveMonitor: MouseMoveMonitoring {
    public private(set) var running = false
    public private(set) var startCount = 0
    private var handler: ((CGPoint) -> Void)?
    public init() {}
    public func start(_ handler: @escaping (CGPoint) -> Void) -> Bool {
        running = true; startCount += 1; self.handler = handler; return true
    }
    public func stop() { running = false; handler = nil }
    public func move(to p: CGPoint) { handler?(p) }
}
