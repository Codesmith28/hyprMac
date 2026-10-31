import AppKit
import HyprKit

let options = AppOptions(arguments: CommandLine.arguments)
if let p = options.eventLogPath { EventLog.shared.open(path: p) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
