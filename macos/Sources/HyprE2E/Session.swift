import AppKit
import ApplicationServices

/// Forced activation through a protocol: avoids the macOS 14 deprecation
/// warning while still being able to hand focus back to the terminal.
private let activateIgnoringOtherApps = NSApplication.ActivationOptions(rawValue: 1 << 1)

/// System state captured before the run and restored after it: the active
/// Space, the frontmost app, and the apps the harness hid.
final class Session {
    let originalSpace: UInt64?
    let originalSpaceIndex: Int?
    let frontmost: NSRunningApplication?
    private var hiddenByUs: [NSRunningApplication] = []
    private let lock = NSLock()
    private var restored = false

    init() {
        originalSpace = Spaces.activeSpace()
        originalSpaceIndex = originalSpace.flatMap { Spaces.index(of: $0) }
        frontmost = NSWorkspace.shared.frontmostApplication
    }

    static var terminalName: String {
        if let t = ProcessInfo.processInfo.environment["TERM_PROGRAM"], !t.isEmpty {
            switch t {
            case "Apple_Terminal": return "Terminal"
            case "iTerm.app": return "iTerm"
            case "vscode": return "Visual Studio Code"
            default: return t
            }
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? "your terminal app"
    }

    /// Exits with 2 and instructions when Accessibility is not granted.
    static func requireAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let term = terminalName
        let msg = """
        hyprmac-e2e: Accessibility permission is missing for the process running this harness.
          1. Open System Settings → Privacy & Security → Accessibility
             (open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
          2. Turn on "\(term)" (the app this harness runs in); add it with "+" if it is not listed.
          3. Quit and reopen "\(term)", then re-run: make test-e2e
        hyprMac is launched as a child of the harness, so it inherits the same grant.
        """
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(2)
    }

    /// Stage Manager regroups and moves windows on its own.
    static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// Other window managers that move windows behind hyprMac's back.
    static func otherWindowManagers() -> [String] {
        let known = ["Rectangle", "yabai", "Amethyst", "AeroSpace", "Magnet", "Moom", "Hammerspoon",
                     "Spectacle", "Divvy", "BetterSnapTool", "Loop", "Swish"]
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        let procs = Set(running)
        return known.filter { procs.contains($0) }
    }

    /// A hyprMac that is not ours would fight the instance under test.
    static func otherHyprMacRunning(app: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { r in
            r.bundleIdentifier == "dev.codesmith28.hyprmac" || r.executableURL?.lastPathComponent == "hyprMac"
        }
    }

    /// Hide every other regular app so only fixture windows get tiled. Hidden
    /// apps are untiled by hyprMac and unhidden again by `restore()`.
    func hideOthers() {
        let me = getpid()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != me {
            if app.hide() { lock.lock(); hiddenByUs.append(app); lock.unlock() }
        }
        let deadline = Date() + 3
        while Date() < deadline && hiddenByUs.contains(where: { !$0.isHidden && !$0.isTerminated }) { pump(0.05) }
    }

    /// Undo everything; safe to call twice and from a signal handler.
    func restore(switchSpace: Bool = true) {
        lock.lock()
        if restored { lock.unlock(); return }
        restored = true
        let apps = hiddenByUs
        lock.unlock()

        if switchSpace, let idx = originalSpaceIndex, let orig = originalSpace, Spaces.activeSpace() != orig {
            if !Keys.switchToSpace(idx) {
                print("# warning: could not return to the original Space (\(idx))")
            }
        }
        for app in apps where !app.isTerminated { app.unhide() }
        if let f = frontmost, !f.isTerminated { f.activate(options: activateIgnoringOtherApps) }
    }
}

/// Screen geometry in top-left-origin points.
enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - (r.minY + r.height), width: r.width, height: r.height)
    }

    /// (frame, visibleFrame) of the screen containing `point` (top-left
    /// coordinates), else of NSScreen.main.
    static func screen(containing point: CGPoint?) -> (frame: CGRect, visible: CGRect) {
        let screens = NSScreen.screens
        let chosen = point.flatMap { p in screens.first { topLeft($0.frame).contains(p) } }
            ?? NSScreen.main ?? screens.first
        guard let s = chosen else { return (.zero, .zero) }
        return (topLeft(s.frame), topLeft(s.visibleFrame))
    }
}
