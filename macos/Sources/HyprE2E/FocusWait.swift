import AppKit
import ApplicationServices

/// Focus the harness can verify: the fixture is told to focus window `i`, then we poll the SYSTEM-WIDE
/// AX focus (the same source hyprMac's hotkeys use) until it is that window. Run 1's custom-keys
/// scenario posted its key before the focus had landed.
enum AXFocus {
    /// The CGWindowID of the system-wide AX focused window, nil when unreadable.
    static func focusedWindowID() -> CGWindowID? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        return Private.windowID(of: win as! AXUIElement)
    }
}

extension Fixture {
    /// `focus i`, then wait (up to `timeout` s, re-sending the command every second) until the AX-focused
    /// window is window `i`. Throws with what WAS focused otherwise.
    func focusAndWait(_ i: Int, timeout: Double = 5) throws {
        let want = try ref(i).id
        let deadline = Date().addingTimeInterval(timeout)
        var lastSent = Date.distantPast
        while Date() < deadline {
            if Date().timeIntervalSince(lastSent) > 1 { try command("focus \(i)"); lastSent = Date() }
            pump(0.05)
            if AXFocus.focusedWindowID() == want { pump(0.15); return } // let hyprMac's own observers see it
        }
        let got = AXFocus.focusedWindowID().map(String.init) ?? "none"
        throw HarnessError("window \(i) (#\(want)) never became the AX-focused window within \(fmt(timeout)) s; focused: #\(got)")
    }
}
