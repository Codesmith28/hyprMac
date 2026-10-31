import AppKit

// hyprmac-e2e: end-to-end tests of hyprMac on the real Mac.
// Output is TAP; exit status 0 = all passed/skipped, 1 = failure, 2 = preflight.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if options.list {
    for s in Catalog.all {
        let req = s.spaces >= 2 ? " [needs >= 2 Spaces]" : ""
        print("\(s.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(s.summary)\(req)")
    }
    exit(0)
}

if options.oracleSelfTest || options.fixtureSelfTest {
    var status: Int32 = 0
    if options.oracleSelfTest && OracleSelfTest.run() != 0 { status = 1 }
    if options.fixtureSelfTest {
        guard let fx = options.fixture, FileManager.default.isExecutableFile(atPath: fx.path) else {
            preflightError("fixture not found at \(options.fixture?.path ?? "?") (pass --fixture)")
        }
        if FixtureSelfTest.run(fixture: fx) != 0 { status = 1 }
    }
    exit(status)
}

// ---- preflight ----
guard let app = options.app else { usageError("--app is required to run scenarios") }
guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/hyprMac").path) else {
    preflightError("\(app.path) has no Contents/MacOS/hyprMac (run `make app`)")
}
guard let fixture = options.fixture, FileManager.default.isExecutableFile(atPath: fixture.path) else {
    preflightError("fixture not found at \(options.fixture?.path ?? "?") (pass --fixture)")
}
var selected: [Scenario] = Catalog.all
if !options.scenarios.isEmpty {
    selected = []
    for name in options.scenarios {
        guard let s = Catalog.named(name) else {
            usageError("unknown scenario '\(name)' (see --list)")
        }
        selected.append(s)
    }
}
Session.requireAccessibility()
if let other = Session.otherHyprMacRunning(app: app) {
    preflightError("another hyprMac is running (pid \(other.processIdentifier)); quit it first so it does not fight the instance under test")
}
if !Spaces.available {
    print("# warning: SkyLight Space functions unavailable; Space scenarios will be skipped")
}

if Session.stageManagerEnabled {
    if options.skipStageManagerCheck {
        print("# warning: Stage Manager is on (check skipped); hyprMac is expected to pause and the run to bail out")
    } else {
        preflightError("Stage Manager is on, so hyprMac pauses tiling: run make install first or turn off Stage Manager")
    }
}
let wms = Session.otherWindowManagers()
if !wms.isEmpty {
    print("# warning: other window managers running (\(wms.joined(separator: ", "))); they may move windows during the run")
}

let session = Session()
if let bundle = session.frontmost?.bundleIdentifier { HyprApp.ignoredBundleIDs = [bundle] }
let spaces = Spaces.userSpaces
print("# user Spaces: \(spaces.count) (ids \(spaces.map(String.init).joined(separator: ","))), current index \(session.originalSpaceIndex.map(String.init) ?? "?")")
print("# frontmost: \(session.frontmost?.localizedName ?? "?") (hyprMac ignores it: rules.ignore = \(HyprApp.ignoredBundleIDs))")

// Ctrl-C / kill: stop children, give the desktop back.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler {
        Children.killAll()
        session.restore(switchSpace: false)
        print("# interrupted")
        exit(130)
    }
    src.resume()
    signalSources.append(src)
}

if options.hideOthers {
    session.hideOthers()
    let foreign = Frames.foreignWindows(excluding: [])
    if !foreign.isEmpty {
        print("# warning: \(foreign.count) other window(s) still on screen: "
              + foreign.prefix(5).map { "\($0.owner) '\($0.title)'" }.joined(separator: ", "))
    }
}

let status = Runner.run(selected, options: options, session: session)
Children.killAll()
session.restore()
exit(status)
