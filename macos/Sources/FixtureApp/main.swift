import AppKit

// hyprmac-fixture: a controllable AppKit test app for the hyprMac E2E harness.
// It is a plain executable (no bundle) that turns itself into a regular,
// AX-visible app, opens windows per the flags, accepts line commands on stdin
// and reports what it did as JSON lines on stdout.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let options: FixtureOptions
do {
    options = try FixtureOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    Out.log("\(error)")
    FileHandle.standardError.write((FixtureOptions.usage + "\n").data(using: .utf8)!)
    exit(64)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = FixtureController(options: options)
app.delegate = controller
app.run()
