import AppKit
import ApplicationServices

enum Onboarding {
    /// First-run / missing-permission explanation, then the system prompt.
    static func showAccessibilityPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to hyprMac"
        alert.informativeText = """
        hyprMac arranges your windows automatically into tiles.

        To move and resize other apps' windows it needs Accessibility access. \
        hyprMac never reads window contents or keystrokes other than its own shortcuts.

        Click “Open System Settings”, enable hyprMac, and tiling starts right away — no restart needed.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func showShortcuts(rows: [ShortcutRow]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "hyprMac shortcuts"
        alert.informativeText = ShortcutList.text(for: rows) + """


        Desktops are your macOS Spaces. Add or remove them in Mission Control.
        Fullscreen windows are never tiled.
        """
        alert.runModal()
    }
}
