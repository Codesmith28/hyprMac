import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

/// Live review #4 and #10: grab-point selection on custom/tabbed titlebars, the window-server
/// cross-check, and physical Shift handling before ⌥N.
@Suite struct GrabPointTests {
    let frame = rect(100, 100, 800, 600)

    func setup(_ regions: [FakeTitlebarRegion], thinBand: Bool = true, windowServer: Bool = true)
        -> (FakeDesktop, WindowRef, SpaceMover) {
        let desk = makeDesk(spaces: 3)
        var q = FakeWindowQuirks(); q.titlebarRegions = regions
        let w = desk.addWindow(pid: 100, id: 1, frame: frame, quirks: q)
        desk.focus(w)
        desk.poster.setCursor(CGPoint(x: 1000, y: 800))
        var cfg = SpaceMover.Configuration(); cfg.thinBandFallback = thinBand
        let mover = SpaceMover(ax: desk.ax, spaces: desk.spaces, displays: desk.displays, poster: desk.poster,
                               clock: desk.clock, windowServer: windowServer ? desk.windowServer : nil, configuration: cfg)
        return (desk, w, mover)
    }

    /// Ghostty with native titlebar tabs: every top+8 candidate is a tab button; only the band
    /// near the edge (top+2…5) hits the AXWindow itself.
    static let ghosttyTabs = [FakeTitlebarRegion(from: 0, to: 1, top: 6, bottom: 28, role: "AXRadioButton")]
    /// Ghostty's plain titlebar: AXGroups whose kAXWindow is missing (unresolvable).
    static let ghosttyGroups = [FakeTitlebarRegion(from: 0, to: 1, top: 6, bottom: 28, role: "AXGroup", resolvesWindow: false)]

    @Test func candidateOrderIsNormalBandThenThinBand() {
        let (_, _, mover) = setup([])
        let ys = mover.candidates(for: frame).map(\.y)
        #expect(ys == [108, 108, 108, 108, 103, 103, 103, 103])
        var cfg = SpaceMover.Configuration(); cfg.thinBandFallback = false
        mover.configuration = cfg
        #expect(mover.candidates(for: frame).count == 4)
        #expect(SpaceMover.Configuration().thinBandFallback) // default ON
    }

    @Test func ghosttyTabsFallBackToThinBand() {
        let (desk, w, mover) = setup(Self.ghosttyTabs)
        #expect(mover.findGrabPoint(for: w, frame: frame) == CGPoint(x: 300, y: 103))
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.space(of: w) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }

    @Test func ghosttyUnresolvableGroupsFallBackToThinBand() {
        let (_, w, mover) = setup(Self.ghosttyGroups)
        #expect(mover.findGrabPoint(for: w, frame: frame) == CGPoint(x: 300, y: 103))
    }

    @Test func withoutThinBandGhosttyHasNoGrabPoint() {
        let (desk, w, mover) = setup(Self.ghosttyTabs, thinBand: false)
        #expect(mover.move(w, toSpace: 2) == .noGrabPoint)
        #expect(desk.posted.isEmpty)
    }

    /// With the backend's kAXParent walk, Ghostty's AXGroup resolves to the window and the normal band works.
    @Test func resolvedGroupIsAcceptedInNormalBand() {
        let (_, w, mover) = setup([FakeTitlebarRegion(from: 0, to: 1, top: 6, bottom: 28, role: "AXGroup")])
        #expect(mover.findGrabPoint(for: w, frame: frame) == CGPoint(x: 300, y: 108))
    }

    @Test func tabStripWithGapUsesNormalBandFirst() {
        // Tabs on the left 60 %, empty draggable strip on the right.
        let (_, w, mover) = setup([FakeTitlebarRegion(from: 0, to: 0.6, top: 6, bottom: 28, role: "AXRadioButton")])
        #expect(mover.findGrabPoint(for: w, frame: frame) == CGPoint(x: 700, y: 108))
    }

    /// The window server must agree the target is topmost at the grab point.
    @Test func windowServerCrossCheckRejectsCoveredPoints() {
        let (desk, w, mover) = setup([])
        // AX (wrongly) claims the target at every point, but another window covers its titlebar.
        desk.ax.hitTestOverride = { _ in AXHit(role: "AXWindow", pid: 100, window: w, isWindowItself: true) }
        desk.addWindow(pid: 100, id: 2, frame: rect(50, 50, 900, 200))
        #expect(mover.findGrabPoint(for: w, frame: frame) == nil)
        let (desk2, w2, unchecked) = setup([], windowServer: false)
        desk2.ax.hitTestOverride = { _ in AXHit(role: "AXWindow", pid: 100, window: w2, isWindowItself: true) }
        desk2.addWindow(pid: 100, id: 2, frame: rect(50, 50, 900, 200))
        #expect(unchecked.findGrabPoint(for: w2, frame: frame) == CGPoint(x: 300, y: 108))
    }

    @Test func topmostWindowIgnoresOtherLayersAndOffscreen() {
        let list = [OnscreenWindow(id: 9, pid: 1, layer: 25, bounds: rect(0, 0, 100, 100)),
                    OnscreenWindow(id: 8, pid: 1, layer: 0, bounds: rect(0, 0, 100, 100), isOnscreen: false),
                    OnscreenWindow(id: 7, pid: 1, layer: 0, bounds: rect(0, 0, 100, 100)),
                    OnscreenWindow(id: 6, pid: 1, layer: 0, bounds: rect(0, 0, 100, 100))]
        #expect(SpaceMover.topmostWindow(at: CGPoint(x: 5, y: 5), in: list) == 7)
        #expect(SpaceMover.topmostWindow(at: CGPoint(x: 500, y: 5), in: list) == nil)
    }

    // MARK: #10 physical Shift

    @Test func noShiftHeldPostsRightAway() {
        let (desk, w, mover) = setup([])
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(mover.lastShiftOutcome == .notHeld)
        #expect(desk.clock.sleeps.first == 0.05 && desk.clock.sleeps[1] == 0.02)
    }

    @Test func waitsForShiftReleaseBeforeOptionN() {
        let (desk, w, mover) = setup([])
        desk.holdModifiers([.maskShift, .maskAlternate], releaseAt: desk.clock.now() + 0.05 + 0.1)
        var keyAt: TimeInterval?
        desk.poster.onPost = { e in if case .keyDown = e { keyAt = desk.clock.now() } }
        let start = desk.clock.now()
        #expect(mover.move(w, toSpace: 2) == .moved)
        guard case .released(let waited)? = mover.lastShiftOutcome else { Issue.record("not released"); return }
        #expect(abs(waited - 0.1) < 0.011)
        #expect(keyAt! - start >= 0.15)
    }

    @Test func postsAnywayAfterShiftTimeout() {
        let (desk, w, mover) = setup([])
        desk.holdModifiers(.maskShift) // never released
        let start = desk.clock.now()
        _ = mover.move(w, toSpace: 2)
        #expect(mover.lastShiftOutcome == .postedWhileHeld)
        #expect(desk.posted.contains(.keyDown(19, .maskAlternate)))
        #expect(desk.clock.now() - start >= 0.05 + 0.3)
    }

    @Test func postImmediatelyPolicySkipsTheWait() {
        let (desk, w, mover) = setup([])
        var cfg = mover.configuration; cfg.shiftRelease = .postImmediately
        mover.configuration = cfg
        desk.holdModifiers(.maskShift)
        _ = mover.move(w, toSpace: 2)
        #expect(mover.lastShiftOutcome == .postedWhileHeld)
        #expect(desk.clock.sleeps[1] == 0.02) // straight to polling the Space
    }

    @Test func mouseEventsArePostedWithoutModifiers() {
        // The synthetic event model carries no flags for mouse events; key events carry exactly ⌥.
        let (desk, w, mover) = setup([])
        desk.holdModifiers([.maskShift, .maskAlternate], releaseAt: desk.clock.now() + 0.01)
        _ = mover.move(w, toSpace: 2)
        let keys = desk.posted.compactMap { e -> CGEventFlags? in
            if case .keyDown(_, let f) = e { return f }; if case .keyUp(_, let f) = e { return f }; return nil
        }
        #expect(keys == [.maskAlternate, .maskAlternate])
    }

    // MARK: - Modern macOS app structures

    @Test func unifiedTitlebarToolbarRoleAccepted() {
        // Standard macOS unified titlebar/toolbar (NSWindowStyleMaskUnifiedTitleAndToolbar)
        let (_, w, mover) = setup([FakeTitlebarRegion(from: 0, to: 1, top: 0, bottom: 28, role: "AXToolbar")])
        let pt = mover.findGrabPoint(for: w, frame: frame)
        #expect(pt == CGPoint(x: 300, y: 108))
    }

    @Test func windowTitleStaticTextAccepted() {
        // Dragging directly on the window title text in macOS titlebars
        let (_, w, mover) = setup([FakeTitlebarRegion(from: 0.2, to: 0.8, top: 0, bottom: 28, role: "AXStaticText")])
        let pt = mover.findGrabPoint(for: w, frame: frame)
        #expect(pt == CGPoint(x: 300, y: 108))
    }

    @Test func electronGenericElementAccepted() {
        // Electron / Chromium titlebar area (VS Code, Slack, Obsidian)
        let (_, w, mover) = setup([FakeTitlebarRegion(from: 0, to: 1, top: 0, bottom: 28, role: "AXGenericElement")])
        let pt = mover.findGrabPoint(for: w, frame: frame)
        #expect(pt == CGPoint(x: 300, y: 108))
    }

    @Test func documentProxyIconAccepted() {
        // Document proxy icon next to file name in titlebar
        let (_, w, _) = setup([FakeTitlebarRegion(from: 0.2, to: 0.26, top: 0, bottom: 28, role: "AXImage")])
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXImage", pid: 100, window: w), for: w))
    }

    @Test func fineGridFindsDraggableStripWhenPrimaryPointsAreTabs() {
        // Tabs covering the 4 primary points (traffic lights + 80, 25%, 50%, 75%):
        // Tab 1: from 0.0 to 0.35 (covers 180 and 300)
        // Tab 2: from 0.45 to 0.85 (covers 500 and 700)
        // Gap between 0.35 and 0.45 is open draggable titlebar space (hits window itself).
        let tabs = [
            FakeTitlebarRegion(from: 0.0, to: 0.35, top: 0, bottom: 28, role: "AXRadioButton"),
            FakeTitlebarRegion(from: 0.45, to: 0.85, top: 0, bottom: 28, role: "AXRadioButton"),
        ]
        let (desk, w, mover) = setup(tabs)
        // Primary candidates all hit tabs; fine-grid finds candidate in the 0.35..0.45 gap (e.g. fraction 0.35 -> x = 380)
        let grab = mover.findGrabPoint(for: w, frame: frame)
        #expect(grab != nil)
        #expect(grab?.x == 380)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.space(of: w) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }

    @Test func windowServerAgreesWithChildOrLayeredSurface() {
        // In Chromium/Electron/JetBrains apps, a child window or layered render surface
        // with the same PID and matching frame sits at layer 0.
        let (_, w, _) = setup([])
        let onscreenWithChild = [
            OnscreenWindow(id: 999, pid: 100, layer: 0, bounds: frame, isOnscreen: true),
            OnscreenWindow(id: 1, pid: 100, layer: 0, bounds: frame, isOnscreen: true),
        ]
        let agrees = SpaceMover.isWindowServerAgreement(
            at: CGPoint(x: 300, y: 108), target: w, frame: frame,
            hit: AXHit(role: "AXWindow", pid: 100, window: w, isWindowItself: true),
            in: onscreenWithChild
        )
        #expect(agrees)
    }
}
