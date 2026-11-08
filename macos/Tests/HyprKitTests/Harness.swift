import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

typealias Ref = HyprPlatform.WindowRef

/// Records every delegate callback (thread-safe).
final class RecordingDelegate: TilingControllerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [TilingNotice] = []
    private var changes = 0

    func tiling(_ controller: TilingController, didPost notice: TilingNotice) {
        lock.lock(); list.append(notice); lock.unlock()
    }
    func tilingStateChanged(_ controller: TilingController) {
        lock.lock(); changes += 1; lock.unlock()
    }
    var notices: [TilingNotice] { lock.lock(); defer { lock.unlock() }; return list }
    var stateChanges: Int { lock.lock(); defer { lock.unlock() }; return changes }
    func count(_ n: TilingNotice) -> Int { notices.filter { $0 == n }.count }
    var throwFailures: [String] {
        notices.compactMap { if case .throwFailed(_, let r) = $0 { return r }; return nil }
    }
}

let mainFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
let mainVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)
/// `mainVisible` inset by the default 12 pt outer gap.
let root = CGRect(x: 12, y: 37, width: 1416, height: 851)
let leftHalf = CGRect(x: 12, y: 37, width: 704, height: 851)
let rightHalf = CGRect(x: 724, y: 37, width: 704, height: 851)

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

/// A Coordinator wired to a FakeDesktop with the REAL engine. Desk events are forwarded to
/// `handle(_:)` on the coordinator queue, so executor writes produce realistic echoes.
final class Harness {
    let desk: FakeDesktop
    let system = FakeSystemState()
    let hotkeys = FakeThrowHotkeys()
    let spaceKeys = FakeSpaceKeyObserver()
    let recorder = RecordingDelegate()
    let configURL: URL
    let c: Coordinator
    let spaceIDs: [SpaceID]

    init(spaces: Int = 3, config: String? = nil, appStateStore: AppStateStore? = nil,
         tuning: Coordinator.Tuning = Coordinator.Tuning(),
         nativeShortcuts: NativeSwitchShortcuts? = nil) {
        desk = FakeDesktop()
        spaceIDs = desk.addDisplay(1, frame: mainFrame, visibleFrame: mainVisible, isMain: true, userSpaces: spaces)
        desk.addApp(pid: 100, bundleID: "com.example.editor")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-kit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("init.lua")
        if let config { try? config.write(to: configURL, atomically: true, encoding: .utf8) }
        let deps = Coordinator.Dependencies(
            ax: desk.ax, windowServer: desk.windowServer, spaces: desk.spaces, displays: desk.displays,
            apps: desk.apps, systemState: system, poster: desk.poster, hotkeys: hotkeys, spaceKeys: spaceKeys,
            nativeShortcuts: nativeShortcuts, clock: desk.clock, makeEvents: nil, onMain: { $0() })
        let stateURL = dir.appendingPathComponent("state.json")
        let store = appStateStore ?? AppStateStore(path: stateURL)
        c = Coordinator(deps: deps, configStore: ConfigStore(path: configURL), appStateStore: store, tuning: tuning)
        c.delegate = recorder
        desk.eventHandler = { [weak c] e in
            guard let c else { return }
            c.queue.async { c.handle(e) }
        }
    }

    deinit { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

    func start() {
        c.start()
        settle()
    }

    func settle(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(c.testSettle(), "coordinator never went idle", sourceLocation: sourceLocation)
    }

    /// Runs one reconcile synchronously, then waits for everything it caused.
    func reconcile() {
        c.queue.sync { c.reconcileNow() }
        settle()
    }

    func send(_ event: PlatformEvent) {
        c.queue.sync { c.handle(event) }
        settle()
    }

    /// Opens a window (focused, like a freshly opened window) and waits for the retile.
    @discardableResult
    func open(_ id: CGWindowID, pid: pid_t = 100, frame: CGRect = rect(200, 200, 400, 300), space: SpaceID? = nil,
              focus: Bool = true, quirks: FakeWindowQuirks = FakeWindowQuirks(), resizable: Bool = true) -> Ref {
        let r = desk.addWindow(pid: pid, id: id, frame: frame, space: space, resizable: resizable, quirks: quirks)
        if focus { desk.focus(r) }
        settle()
        return r
    }

    func frame(_ r: Ref) -> CGRect? { desk.frame(of: r) }
    func id(_ r: Ref) -> UInt64? { c.testEngineID(r) }
    func tiled(_ space: SpaceID) -> Int { c.testTiledCount(space: space) }
    var s1: SpaceID { spaceIDs[0] }
    var s2: SpaceID { spaceIDs[1] }
    var s3: SpaceID { spaceIDs[2] }

    /// Writes `init.lua` and asks the coordinator to reload it.
    func reload(_ lua: String) {
        try? lua.write(to: configURL, atomically: true, encoding: .utf8)
        c.reloadConfig()
        settle()
    }
}

func gapsLua(inner: Double, outer: Double) -> String {
    "config = { gaps = { inner = \(inner), outer = \(outer) } }\n"
}
