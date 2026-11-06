import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

@Suite struct SpaceMoverTests {
    let frame = rect(100, 100, 800, 600)

    func setup(spaces: Int = 3) -> (FakeDesktop, WindowRef, SpaceMover) {
        let desk = makeDesk(spaces: spaces)
        let w = desk.addWindow(pid: 100, id: 1, frame: frame)
        desk.focus(w)
        desk.poster.setCursor(CGPoint(x: 1000, y: 800))
        let mover = SpaceMover(ax: desk.ax, spaces: desk.spaces, displays: desk.displays, poster: desk.poster, clock: desk.clock)
        return (desk, w, mover)
    }

    @Test func grabCandidates() {
        let pts = SpaceMover.grabCandidates(for: frame)
        #expect(pts == [CGPoint(x: 300, y: 108), CGPoint(x: 500, y: 108), CGPoint(x: 700, y: 108), CGPoint(x: 180, y: 108)])
        // Traffic-lights candidate is clamped inside narrow windows.
        #expect(SpaceMover.grabCandidates(for: rect(0, 0, 60, 60)).last == CGPoint(x: 59, y: 8))
    }

    @Test func grabAcceptance() {
        let w = WindowRef(pid: 1, windowID: 1), other = WindowRef(pid: 1, windowID: 2)
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXWindow", pid: 1, window: w, isWindowItself: true), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXGroup", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXUnknown", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXToolbar", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXTabGroup", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXStaticText", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXGenericElement", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXImage", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXHeading", pid: 1, window: w), for: w))
        #expect(SpaceMover.isAcceptableGrab(AXHit(role: "AXSplitGroup", pid: 1, window: w), for: w))
        #expect(!SpaceMover.isAcceptableGrab(AXHit(role: "AXGroup", pid: 1, window: other), for: w))
        #expect(!SpaceMover.isAcceptableGrab(AXHit(role: "AXGroup", pid: 1, window: nil), for: w))
        #expect(!SpaceMover.isAcceptableGrab(nil, for: w))
    }

    @Test(arguments: ["AXButton", "AXRadioButton", "AXTab", "AXTextField", "AXSearchField", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXCheckBox"])
    func controlsRejected(_ role: String) {
        let w = WindowRef(pid: 1, windowID: 1)
        #expect(!SpaceMover.isAcceptableGrab(AXHit(role: role, pid: 1, window: w), for: w))
    }

    @Test func movesWithExactEventSequence() throws {
        let (desk, w, mover) = setup()
        let target = try #require(desk.spaces.userSpace(index: 2, display: 1))
        #expect(mover.move(w, toSpace: 2) == .moved)
        let grab = CGPoint(x: 300, y: 108)
        #expect(desk.posted == [
            .mouseMove(grab), .leftMouseDown(grab),
            .keyDown(19, .maskAlternate), .keyUp(19, .maskAlternate),
            .leftMouseUp(grab), .warpCursor(CGPoint(x: 1000, y: 800)),
        ])
        #expect(desk.space(of: w) == target.id)
        #expect(desk.spaces.activeSpace(display: 1) == target.id)
        #expect(desk.cursorPosition == CGPoint(x: 1000, y: 800))
        let sleeps = desk.clock.sleeps
        #expect(sleeps.first == 0.05)
        #expect(sleeps.last == 0.4) // settle before mouse-up
        #expect(sleeps.dropFirst().dropLast().allSatisfy { $0 == 0.02 })
    }

    @Test func noSuchSpaceReportsCount() {
        let (desk, w, mover) = setup(spaces: 3)
        #expect(mover.move(w, toSpace: 5) == .noSuchSpace(requested: 5, available: 3))
        #expect(desk.posted.isEmpty)
    }

    @Test func noSuchSpaceWithoutSkyLightHasUnknownCount() {
        let (desk, w, mover) = setup(spaces: 3)
        desk.spacesUnavailable = true
        #expect(mover.move(w, toSpace: 2) == .noSuchSpace(requested: 2, available: nil))
        #expect(mover.move(w, toSpace: 1) == .alreadyThere)
    }

    @Test func alreadyThere() {
        let (desk, w, mover) = setup()
        #expect(mover.move(w, toSpace: 1) == .alreadyThere)
        #expect(desk.posted.isEmpty)
    }

    @Test func refusesFullscreenWindow() {
        let (desk, w, mover) = setup()
        desk.setFullscreen(w, true)
        #expect(mover.move(w, toSpace: 2) == .refusedFullscreen)
        #expect(desk.posted.isEmpty)
    }

    @Test func noGrabPointWhenTitlebarIsAllControls() {
        let (desk, w, mover) = setup()
        desk.updateQuirks(w) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, role: "AXRadioButton")] }
        #expect(mover.move(w, toSpace: 2) == .noGrabPoint)
        #expect(desk.posted.isEmpty)
        // Primary candidates + fine-grid candidates are all checked and rejected.
        let calls = desk.axCalls.filter { if case .elementAt = $0 { return true }; return false }.count
        #expect(calls > 8)
    }

    /// Quirk 15: the first candidate hits a tab button, the next one hits the titlebar.
    @Test func skipsTabButtonAndUsesTitlebar() {
        let (desk, w, mover) = setup()
        desk.updateQuirks(w) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0.2, to: 0.3, role: "AXRadioButton")] }
        #expect(mover.move(w, toSpace: 3) == .moved)
        #expect(desk.posted[1] == .leftMouseDown(CGPoint(x: 500, y: 108)))
    }

    /// Spike S7/S8: Chrome's tab strip is AXGroup at 25/50/75 %, but traffic lights + 80 is an AXButton.
    @Test func chromeLikeTitlebar() {
        let (desk, w, mover) = setup()
        var calls: [CGPoint] = []
        desk.ax.hitTestOverride = { p in
            calls.append(p)
            return p.x == 180 ? AXHit(role: "AXButton", pid: 100, window: w) : AXHit(role: "AXGroup", pid: 100, window: w)
        }
        #expect(mover.findGrabPoint(for: w, frame: frame) == CGPoint(x: 300, y: 108))
        #expect(!SpaceMover.isAcceptableGrab(desk.ax.hitTestOverride!(CGPoint(x: 180, y: 108)), for: w))
    }

    @Test func overlappingWindowAtGrabPointIsRejected() {
        let (desk, w, mover) = setup()
        // A window in front covers the left half of the titlebar.
        desk.addWindow(pid: 100, id: 2, frame: rect(0, 50, 550, 300))
        #expect(mover.findGrabPoint(for: w, frame: frame) == CGPoint(x: 700, y: 108))
    }

    @Test func timeoutStillReleasesMouseAndRestoresCursor() {
        let (desk, w, mover) = setup()
        desk.nativeSwitchEnabled = false
        let start = desk.clock.now()
        #expect(mover.move(w, toSpace: 2) == .timedOut)
        #expect(desk.clock.now() - start >= 1.0)
        #expect(desk.posted.suffix(2) == [.leftMouseUp(CGPoint(x: 300, y: 108)), .warpCursor(CGPoint(x: 1000, y: 800))])
        #expect(desk.cursorPosition == CGPoint(x: 1000, y: 800))
        #expect(desk.space(of: w) == desk.spaces.userSpace(index: 1, display: 1)?.id)
    }

    /// Spike S10: a ⌥N during a running transition is dropped → the mover times out (and cleans up).
    @Test func switchDroppedDuringTransitionTimesOut() {
        let (desk, w, mover) = setup()
        desk.poster.post(.keyDown(20, .maskAlternate)) // someone switched to Space 3 just now
        desk.clock.advance(by: 0.4)                    // switch landed, animation still running
        #expect(desk.spaces.activeSpace(display: 1) == desk.spaces.userSpace(index: 3, display: 1)?.id)
        _ = desk.ax // window is on Space 1, which isn't visible anymore; put it on 3 for the hit test
        desk.moveWindow(w, toSpace: desk.spaces.userSpace(index: 3, display: 1)!.id)
        #expect(mover.move(w, toSpace: 2) == .timedOut)
        #expect(desk.droppedSwitches == 1)
        #expect(desk.posted.last == .warpCursor(CGPoint(x: 1000, y: 800)))
    }

    @Test func transitionGuardRefusesEarly() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: frame)
        let guardian = SpaceTransitionGuard(settle: 0.5)
        guardian.noteTransition(at: desk.clock.now())
        let mover = SpaceMover(ax: desk.ax, spaces: desk.spaces, displays: desk.displays, poster: desk.poster,
                               clock: desk.clock, transitions: guardian)
        #expect(mover.move(w, toSpace: 2) == .transitionInFlight)
        #expect(desk.posted.isEmpty)
        desk.clock.advance(by: 0.6)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(!guardian.canSwitch(now: desk.clock.now())) // the throw itself started a transition
    }

    /// Spike S4: index N maps to the N-th user Space, not to the raw id.
    @Test func nonContiguousSpaceIds() {
        let desk = FakeDesktop()
        desk.addDisplay(1, frame: mainFrame, visibleFrame: mainVisible, isMain: true, userSpaces: 1) // id 1
        desk.addSpace(display: 1, id: 5)
        desk.addSpace(display: 1, id: 20, kind: .fullscreen)
        desk.addSpace(display: 1, id: 8)
        desk.addApp(pid: 100, bundleID: "x")
        let w = desk.addWindow(pid: 100, id: 1, frame: frame)
        let mover = SpaceMover(ax: desk.ax, spaces: desk.spaces, displays: desk.displays, poster: desk.poster, clock: desk.clock)
        #expect(mover.move(w, toSpace: 3) == .moved)
        #expect(desk.space(of: w) == 8)
        #expect(desk.posted.contains(.keyDown(20, .maskAlternate)))
    }

    @Test func goneWindowFails() {
        let (desk, w, mover) = setup()
        desk.closeWindow(w)
        #expect(mover.move(w, toSpace: 2) == .failed(.invalidUIElement))
        #expect(desk.posted.isEmpty)
    }

    /// Quirk 14: throws on a secondary display at negative coordinates use that display's Spaces.
    @Test func throwOnSecondaryDisplay() {
        let desk = makeDesk(spaces: 2)
        let ids = desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080), userSpaces: 2)
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(-1800, -100, 800, 600))
        desk.poster.setCursor(CGPoint(x: -100, y: 0))
        let mover = SpaceMover(ax: desk.ax, spaces: desk.spaces, displays: desk.displays, poster: desk.poster, clock: desk.clock)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.space(of: w) == ids[1])
        #expect(desk.spaces.activeSpace(display: 1) == desk.spaces.userSpace(index: 1, display: 1)?.id)
        #expect(desk.cursorPosition == CGPoint(x: -100, y: 0))
    }

    @Test func throwWindowWithUnifiedToolbar() {
        let (desk, w, mover) = setup()
        desk.updateQuirks(w) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, role: "AXToolbar")] }
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.space(of: w) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }

    @Test func throwWindowWithTitleText() {
        let (desk, w, mover) = setup()
        desk.updateQuirks(w) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0.2, to: 0.8, role: "AXStaticText")] }
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.space(of: w) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }

    @Test func throwWindowWithElectronGenericElement() {
        let (desk, w, mover) = setup()
        desk.updateQuirks(w) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, role: "AXGenericElement")] }
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.space(of: w) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }
}

@Suite struct FakeDesktopTests {
    @Test func tabsShareFrameWhenOneMoves() throws {
        let desk = makeDesk()
        let tabs = desk.addTabs(pid: 100, ids: [1, 2], frame: rect(0, 25, 500, 500))
        try desk.ax.setPosition(CGPoint(x: 50, y: 60), of: tabs[0])
        #expect(desk.frame(of: tabs[1])?.origin == CGPoint(x: 50, y: 60))
        #expect(desk.isOnscreen(tabs[0]) && !desk.isOnscreen(tabs[1]))
    }

    @Test func hungAppCallsBlockForMessagingTimeout() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        desk.setHung(pid: 100, true, duration: 30)
        desk.ax.setMessagingTimeout(pid: 100, seconds: 0.05)
        let start = Date()
        #expect(throws: AXBackendError.cannotComplete) { try desk.ax.frame(of: w) }
        let t = Date().timeIntervalSince(start)
        #expect(t >= 0.04 && t < 0.5)
    }

    @Test func minimizeViaAXAndFocus() throws {
        let desk = makeDesk()
        let a = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let b = desk.addWindow(pid: 100, id: 2, frame: rect(0, 25, 500, 500))
        try desk.ax.setBool(.focused, true, of: a)
        #expect(try desk.ax.focusedApplication() == 100)
        #expect(try desk.ax.focusedWindow(pid: 100) == a)
        #expect(try desk.ax.bool(.main, of: a))
        try desk.ax.setBool(.minimized, true, of: b)
        #expect(try desk.ax.bool(.minimized, of: b))
        #expect(desk.spaces.spaces(of: 2).isEmpty) // minimized: no Space info
        #expect(desk.spaces.spaces(of: 1) == [desk.spaces.activeSpace(display: 1)])
    }

    @Test func goneAppAndWindowRaiseInvalidElement() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        desk.terminate(pid: 100)
        #expect(throws: AXBackendError.invalidUIElement) { try desk.ax.frame(of: w) }
        #expect(desk.apps.application(pid: 100) == nil)
    }
}
