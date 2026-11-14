import AppKit
import ApplicationServices

/// Which display the OSD appears on: the one holding the window that was acted on, else the mouse's.
enum OSDDisplay {
    /// Index into `screenFrames` (AppKit bottom-left coordinates). `axFrame` is a window frame in
    /// Accessibility's top-left coordinates; `primaryHeight` converts between the two.
    static func screenIndex(axFrame: CGRect?, screenFrames: [CGRect], primaryHeight: CGFloat,
                            mouse: CGPoint) -> Int? {
        if let ax = axFrame, ax.width > 0, ax.height > 0 {
            let appKit = CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
            let centre = CGPoint(x: appKit.midX, y: appKit.midY)
            if let i = screenFrames.firstIndex(where: { $0.contains(centre) }) { return i }
            let overlaps = screenFrames.enumerated().map { ($0.offset, $0.element.intersection(appKit)) }
                .filter { !$0.1.isNull && $0.1.width * $0.1.height > 0 }
            if let best = overlaps.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) { return best.0 }
        }
        return screenFrames.firstIndex(where: { $0.contains(mouse) })
    }

    /// The screen to show on, or nil to let the caller fall back to `NSScreen.main`.
    static func currentScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        guard let i = screenIndex(axFrame: focusedWindowFrame(), screenFrames: screens.map(\.frame),
                                  primaryHeight: primary.frame.height, mouse: NSEvent.mouseLocation) else { return nil }
        return screens[i]
    }

    /// Frame of the focused window in Accessibility coordinates; nil when there is none or AX fails.
    static func focusedWindowFrame() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        let appElement = app as! AXUIElement
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let w = window as! AXUIElement
        var pos: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
