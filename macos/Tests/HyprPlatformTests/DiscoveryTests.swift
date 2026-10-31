import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

@Suite struct DiscoveryTests {
    @Test func basicSnapshotFrontToBackWithFocus() throws {
        let desk = makeDesk()
        let a = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800))
        desk.addApp(pid: 200, bundleID: "com.example.term")
        let b = desk.addWindow(pid: 200, id: 2, frame: rect(700, 25, 700, 800))
        desk.focus(a)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.display == 1)
        #expect(snap.space == desk.spaces.activeSpace(display: 1))
        #expect(snap.usable == mainVisible)
        #expect(snap.windows.map(\.ref) == [a, b])
        #expect(snap.windows.allSatisfy { $0.state == .tiled && $0.membership == .confirmed })
        #expect(snap.focused == a)
        #expect(snap.unresolved.isEmpty && snap.unresponsivePids.isEmpty)
    }

    @Test func unknownDisplayGivesNil() {
        #expect(makeDiscovery(makeDesk()).snapshot(display: 99) == nil)
    }

    @Test func windowsOnOtherSpacesAreLeftOut() throws {
        let desk = makeDesk(spaces: 2)
        let here = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800))
        desk.addWindow(pid: 100, id: 2, frame: rect(0, 25, 700, 800), space: desk.spaces.userSpace(index: 2, display: 1)!.id)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.map(\.ref) == [here])
    }

    /// Quirk 7: native tabs share a frame; only the on-screen tab is kept.
    @Test func nativeTabsDeduplicatedToOnscreenTab() throws {
        let desk = makeDesk()
        let tabs = desk.addTabs(pid: 100, ids: [10, 11, 12], frame: rect(0, 25, 900, 700), selected: 1)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.map(\.ref) == [tabs[1]])
    }

    @Test func dedupeKeepsOverlappingWindowsThatAreBothVisible() {
        let f = rect(0, 0, 100, 100)
        let w = [WindowRef(pid: 1, windowID: 1), WindowRef(pid: 1, windowID: 2), WindowRef(pid: 2, windowID: 3)].map {
            DiscoveredWindow(ref: $0, state: .tiled, frame: f, minSize: nil, membership: .confirmed)
        }
        #expect(WindowDiscovery.dedupeTabs(w, isOnscreen: { _ in true }).count == 3)
        // None on screen: keep the first of the pid group.
        #expect(WindowDiscovery.dedupeTabs(w, isOnscreen: { _ in false }).map(\.ref.windowID) == [1, 3])
    }

    /// Quirk 8: sheets, dialogs and panels never reach the snapshot.
    @Test func sheetsDialogsAndPanelsExcluded() throws {
        let desk = makeDesk()
        let main = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 900, 700))
        desk.addWindow(pid: 100, id: 2, frame: rect(100, 50, 400, 200), role: "AXSheet", subrole: nil)
        desk.addWindow(pid: 100, id: 3, frame: rect(300, 300, 400, 200), subrole: "AXDialog")
        desk.addWindow(pid: 100, id: 4, frame: rect(900, 100, 200, 400), subrole: "AXFloatingWindow", layer: 3)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.map(\.ref) == [main])
    }

    /// Quirk 9: non-resizable windows float.
    @Test func nonResizableWindowFloats() throws {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 400, 300), resizable: false)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.first { $0.ref == w }?.state == .floating)
    }

    /// Quirk 12: minimized windows and hidden apps stay in the snapshot as ghosts.
    @Test func minimizedAndHiddenAreGhosts() throws {
        let desk = makeDesk()
        let m = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800))
        desk.setMinimized(m, true)
        desk.addApp(pid: 200, bundleID: "com.example.hidden")
        let h = desk.addWindow(pid: 200, id: 2, frame: rect(700, 25, 700, 800))
        desk.setAppHidden(pid: 200, true)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        let byRef = Dictionary(uniqueKeysWithValues: snap.windows.map { ($0.ref, $0) })
        #expect(byRef[m]?.state == .minimized)
        #expect(byRef[m]?.membership == .inferred)
        #expect(byRef[h]?.state == .hidden)
        #expect(desk.windowServer.onscreenWindows().isEmpty)
    }

    /// Quirk 11: a fullscreen window lives on its own Space but keeps its ghost in the user Space snapshot.
    @Test func fullscreenWindowKeptAsInferredGhost() throws {
        let desk = makeDesk()
        let userSpace = desk.spaces.activeSpace(display: 1)
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800))
        let other = desk.addWindow(pid: 100, id: 2, frame: rect(700, 25, 700, 800))
        desk.setFullscreen(w, true)
        #expect(desk.spaces.activeSpace(display: 1) != userSpace)
        #expect(try desk.ax.facts(of: w).subrole == "AXStandardWindow")
        // Back on the user Space, the fullscreen window is a ghost.
        let fsSpace = desk.spaces.activeSpace(display: 1)
        desk.setActiveSpace(userSpace, display: 1)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.first { $0.ref == w }?.state == .fullscreen)
        #expect(snap.windows.first { $0.ref == w }?.membership == .inferred)
        #expect(snap.windows.first { $0.ref == other }?.state == .tiled)
        // Exiting fullscreen restores the window to its user Space.
        desk.setActiveSpace(fsSpace, display: 1)
        desk.setFullscreen(w, false)
        #expect(desk.space(of: w) == userSpace)
        #expect(desk.frame(of: w) == rect(0, 25, 700, 800))
    }

    /// Quirk 5: a window that isn't ready for one call is retried immediately.
    @Test func notReadyWindowRetriedOnce() throws {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.notReadyCalls = 1
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800), quirks: q)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.map(\.ref) == [w])
        #expect(snap.unresolved.isEmpty)
    }

    @Test func persistentlyNotReadyWindowIsUnresolvedNotDropped() throws {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.notReadyCalls = 10
        let bad = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800), quirks: q)
        let good = desk.addWindow(pid: 100, id: 2, frame: rect(700, 25, 700, 800))
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.map(\.ref) == [good])
        #expect(snap.unresolved == [bad])
    }

    /// Quirk 4: a hung app is abandoned quickly and doesn't hide other apps' windows.
    @Test func hungAppReportedUnresponsiveWithoutBlocking() throws {
        let desk = makeDesk()
        desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800))
        desk.addApp(pid: 200, bundleID: "com.example.ok")
        let ok = desk.addWindow(pid: 200, id: 2, frame: rect(700, 25, 700, 800))
        desk.setHung(pid: 100, true, duration: 30)
        var cfg = WindowDiscovery.Configuration()
        cfg.messagingTimeout = 0.05
        let d = WindowDiscovery(ax: desk.ax, windowServer: desk.windowServer, spaces: desk.spaces,
                                displays: desk.displays, apps: desk.apps, configuration: cfg)
        let start = Date()
        let snap = try #require(d.snapshot(display: 1))
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(snap.unresponsivePids == [100])
        #expect(snap.windows.map(\.ref) == [ok])
        #expect(desk.messagingTimeout(pid: 100) == 0.05)
    }

    @Test func hungAfterListingSkipsRestOfApp() throws {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.notReadyCalls = 100
        let refs = (1...5).map { desk.addWindow(pid: 100, id: CGWindowID($0), frame: rect(CGFloat($0) * 10, 25, 300, 300), quirks: q) }
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(Set(snap.unresolved) == Set(refs))
        #expect(snap.unresponsivePids == [100])
        // Only the first two windows were actually queried (2 attempts each).
        #expect(desk.axCalls.filter { if case .facts = $0 { return true }; return false }.count == 4)
    }

    /// Quirk 14: per-display snapshots with a display at negative coordinates.
    @Test func multiDisplayNegativeCoordinates() throws {
        let desk = makeDesk()
        desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080), visibleFrame: rect(-1920, -155, 1920, 1055))
        let left = desk.addWindow(pid: 100, id: 1, frame: rect(-1800, -100, 800, 600))
        let right = desk.addWindow(pid: 100, id: 2, frame: rect(100, 100, 800, 600))
        let d = makeDiscovery(desk)
        let s2 = try #require(d.snapshot(display: 2))
        let s1 = try #require(d.snapshot(display: 1))
        #expect(s2.windows.map(\.ref) == [left])
        #expect(s2.usable == rect(-1920, -155, 1920, 1055))
        #expect(s1.windows.map(\.ref) == [right])
        #expect(s1.space != s2.space)
    }

    @Test func fallbackWithoutSkyLightUsesVisibility() throws {
        let desk = makeDesk(spaces: 2)
        desk.spacesUnavailable = true
        let here = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800))
        desk.addWindow(pid: 100, id: 2, frame: rect(0, 25, 700, 800), space: 2) // other (real) Space: not on screen
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.space == SyntheticSpaces.id(for: 1))
        #expect(snap.windows.map(\.ref) == [here])
    }

    @Test func accessoryAndOwnAppsAreNeverQueried() throws {
        let desk = makeDesk()
        desk.addApp(pid: 300, bundleID: "com.example.menubar", policy: .accessory)
        desk.addWindow(pid: 300, id: 30, frame: rect(0, 25, 100, 100))
        desk.addApp(pid: 400, bundleID: WindowEligibility.ownBundleID)
        desk.addWindow(pid: 400, id: 40, frame: rect(0, 25, 100, 100))
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.isEmpty)
        #expect(!desk.axCalls.contains { $0 == .windows(300) || $0 == .windows(400) })
    }

    /// Quirk 13: after a relaunch the same CGWindowIDs come back under a new pid.
    @Test func relaunchedAppYieldsNewRefsWithSameIDs() throws {
        let desk = makeDesk()
        let old = desk.addWindow(pid: 100, id: 7, frame: rect(0, 25, 700, 800))
        let new = desk.relaunch(pid: 100, as: 101)
        #expect(new.map(\.windowID) == [7])
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.map(\.ref) == new)
        #expect(!snap.windows.contains { $0.ref == old })
    }

    @Test func exposedMinSizeIsReported() throws {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 500, height: 400); q.exposesMinSize = true
        desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 700, 800), quirks: q)
        let snap = try #require(makeDiscovery(desk).snapshot(display: 1))
        #expect(snap.windows.first?.minSize == CGSize(width: 500, height: 400))
    }

    @Test func orderPutsOnscreenFirst() {
        let ws = (1...4).map {
            DiscoveredWindow(ref: WindowRef(pid: 1, windowID: CGWindowID($0)), state: .tiled, frame: .zero, minSize: nil, membership: .confirmed)
        }
        let idx: [CGWindowID: Int] = [3: 0, 1: 1]
        #expect(WindowDiscovery.order(ws, onscreenIndex: { idx[$0.windowID] }).map(\.ref.windowID) == [3, 1, 2, 4])
    }
}
