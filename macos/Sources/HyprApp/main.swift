import AppKit
import HyprKit
import HyprPlatform

// Enforce single instance per user session.
let instanceLock = SingleInstanceLock()
switch instanceLock.acquire() {
case .acquired:
    break
case .alreadyRunning(let pid):
    fputs("[hyprMac] Another instance is already running (PID \(pid)). Exiting duplicate instance.\n", stderr)
    exit(0)
case .lockHeldByOtherProcess:
    fputs("[hyprMac] Another instance holds the startup lock. Exiting duplicate instance.\n", stderr)
    exit(0)
case .cannotCreateLockDirectory(let msg):
    fputs("[hyprMac] Warning: Could not create lock directory: \(msg)\n", stderr)
    // Non-fatal warning; proceed if LaunchServices check passed
}

let options = AppOptions(arguments: CommandLine.arguments)
if let p = options.eventLogPath { EventLog.shared.open(path: p) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
