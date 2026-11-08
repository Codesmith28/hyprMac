import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// ⌥⇧N throws (drag trick through the fake poster) and ⌥N missing-space notices.
@Suite struct ThrowTests {
    /// Space 1: A (focused), B. Space 2: C. Clock moved past any transition.
    func setup() -> (Harness, Ref, Ref, Ref) {
        let h = Harness(); h.start()
        let c = h.desk.addWindow(pid: 100, id: 3, frame: rect(100, 100, 600, 500), space: h.s2)
        let b = h.open(2)
        let a = h.open(1)
        h.desk.focus(a); h.settle()
        h.desk.clock.advance(by: 2)
        return (h, a, b, c)
    }

    func throwFocused(_ h: Harness, _ n: Int) {
        h.c.throwFocusedWindow(toSpace: n)
        h.settle()
    }

    @Test func throwMovesWindowAndRetilesBothSpaces() {
        let (h, a, b, c) = setup()
        #expect(h.frame(b) == leftHalf && h.frame(a) == rightHalf)
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.desk.spaces.activeSpace(display: 1) == h.s2)
        let halves = [h.frame(a)!, h.frame(c)!].sorted { $0.minX < $1.minX }
        #expect(halves == [leftHalf, rightHalf])
        #expect(h.frame(b) == root) // the source Space closed the hole right away
        #expect(h.tiled(h.s1) == 1 && h.tiled(h.s2) == 2)
        #expect(h.c.testSpaceOf(h.id(a)!) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
        #expect(h.recorder.notices == [.windowThrown(app: "com.example.editor", fromSpace: 1, toSpace: 2)])
        // The drag trick released the mouse and put the cursor back.
        #expect(h.desk.posted.contains(.keyDown(19, .maskAlternate)))
        if case .warpCursor = h.desk.posted.last {} else { Issue.record("cursor not restored") }
    }

    @Test func throwViaHotkey() {
        let (h, a, _, _) = setup()
        h.hotkeys.press(3)
        h.settle()
        #expect(h.desk.space(of: a) == h.s3)
        #expect(h.frame(a) == root)
    }

    @Test func throwToCurrentSpaceDoesNothing() {
        let (h, a, b, _) = setup()
        throwFocused(h, 1)
        #expect(h.desk.posted.isEmpty)
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.frame(b) == leftHalf && h.frame(a) == rightHalf)
        #expect(h.recorder.notices.isEmpty)
    }

    @Test func throwToMissingSpaceNotifies() {
        let (h, a, _, _) = setup()
        throwFocused(h, 7)
        #expect(h.recorder.notices == [.missingSpace(requested: 7, count: 3)])
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.desk.posted.isEmpty)
    }

    @Test func throwWithoutSkyLightHasNoCountAndNoNotice() {
        let (h, a, _, _) = setup()
        h.desk.spacesUnavailable = true
        throwFocused(h, 2)
        #expect(h.recorder.notices.isEmpty)
        #expect(h.desk.space(of: a) == h.s1)
    }

    @Test func throwRefusesFullscreen() {
        let (h, a, _, _) = setup()
        h.desk.setFullscreen(a, true); h.settle()
        h.desk.clock.advance(by: 2)
        throwFocused(h, 2)
        #expect(h.recorder.throwFailures == ["Fullscreen windows can't be moved."])
        #expect(h.desk.posted.isEmpty)
    }

    @Test func throwWithoutGrabPointNotifies() {
        let (h, a, _, _) = setup()
        h.desk.updateQuirks(a) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, role: "AXButton")] }
        throwFocused(h, 2)
        #expect(h.recorder.throwFailures == ["This window has no titlebar area to grab."])
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.desk.posted.isEmpty)
    }

    @Test func throwTimeoutNotifiesAndKeepsLayout() throws {
        let (h, a, b, _) = setup()
        h.desk.nativeSwitchEnabled = false
        let fa = try #require(h.frame(a))
        let grab = try #require(h.c.mover.findGrabPoint(for: a, frame: fa))
        throwFocused(h, 2)
        #expect(h.recorder.throwFailures.count == 1)
        #expect(h.recorder.throwFailures.first?.contains("Switch to Desktop 2") == true)
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.frame(b) == leftHalf && h.frame(a) == rightHalf)
        #expect(h.desk.posted.suffix(2).first == .leftMouseUp(grab))
    }

    /// Real macOS (throw-rapid E2E): a second press during a throw used to vanish silently. Both calls
    /// are queued on the coordinator queue before the first throw's completion can run, so the second
    /// always sees `throwInFlight`.
    @Test func throwPressedWhileAnotherIsInFlightIsQueuedNotLost() {
        let (h, a, _, _) = setup()
        h.c.throwFocusedWindow(toSpace: 2)
        h.c.throwFocusedWindow(toSpace: 3)
        // Let the animation of the first throw "finish" while the queued one waits to run.
        for _ in 0..<100 where h.desk.space(of: a) != h.s3 {
            h.desk.clock.advance(by: 1)
            Thread.sleep(forTimeInterval: 0.05)
        }
        h.settle()
        #expect(h.desk.space(of: a) == h.s3)
        #expect(h.recorder.throwFailures.isEmpty)
        #expect(h.recorder.notices == [.windowThrown(app: "com.example.editor", fromSpace: 1, toSpace: 2), .windowThrown(app: "com.example.editor", fromSpace: 2, toSpace: 3)])
    }

    @Test func throwDuringTransitionIsRetriedAfterSettling() {
        let (h, a, _, _) = setup()
        h.send(.activeSpaceChanged) // a transition just started
        h.c.throwFocusedWindow(toSpace: 2)
        h.c.queue.sync {}
        h.desk.clock.advance(by: 1) // the animation finishes before the retry fires
        h.settle()
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
        #expect(h.recorder.notices == [.windowThrown(app: "com.example.editor", fromSpace: 1, toSpace: 2)])
    }

    @Test func throwMovesWindowLeftDirection() {
        let (h, a, _, _) = setup()
        throwFocused(h, 2)
        #expect(h.recorder.notices.contains(.windowThrown(app: "com.example.editor", fromSpace: 1, toSpace: 2)))
        h.desk.clock.advance(by: 2)
        h.desk.focus(a)
        h.settle()
        throwFocused(h, 1)
        #expect(h.recorder.notices.contains(.windowThrown(app: "com.example.editor", fromSpace: 2, toSpace: 1)))
    }

    @Test func throwDuringEndlessTransitionGivesUpQuietly() {
        var t = Coordinator.Tuning(); t.throwRetries = 1
        let h = Harness(tuning: t); h.start()
        let a = h.open(1)
        h.send(.activeSpaceChanged) // fake clock never advances: always in flight
        h.c.throwFocusedWindow(toSpace: 2)
        h.settle()
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.desk.posted.isEmpty)
        #expect(h.recorder.notices.isEmpty)
    }

    @Test func throwAxFailureNotifies() {
        let (h, a, _, _) = setup()
        h.desk.updateQuirks(a) { $0.notReadyCalls = 1 }
        throwFocused(h, 2)
        #expect(h.recorder.throwFailures == ["Accessibility error: cannotComplete"])
        #expect(h.desk.space(of: a) == h.s1)
    }

    @Test func throwWithoutFocusedWindowIsIgnored() {
        let h = Harness(); h.start()
        throwFocused(h, 2)
        #expect(h.desk.posted.isEmpty)
        #expect(h.recorder.notices.isEmpty)
    }

    @Test func missingSpaceNoticeCountsUserSpacesOnly() {
        let h = Harness(); h.start()
        h.open(1)
        h.desk.addSpace(display: 1, kind: .fullscreen) // 3 user + 1 fullscreen Space
        h.spaceKeys.key(21, flags: .maskAlternate)  // ⌥4
        h.settle()
        #expect(h.recorder.notices == [.missingSpace(requested: 4, count: 3)])
        h.spaceKeys.key(20, flags: .maskAlternate)  // ⌥3 exists
        h.spaceKeys.key(25, flags: [.maskAlternate, .maskShift]) // not a switch
        h.settle()
        #expect(h.recorder.notices == [.missingSpace(requested: 4, count: 3), .spaceSwitched(toSpace: 3)])
    }

    @Test func spaceKeyStartsTransitionSoThrowWaits() {
        let (h, a, _, _) = setup()
        h.spaceKeys.key(20, flags: .maskAlternate) // ⌥3: macOS starts animating
        h.c.throwFocusedWindow(toSpace: 2)
        h.c.queue.sync {}
        h.desk.clock.advance(by: 1)
        h.settle()
        #expect(h.desk.space(of: a) == h.s2) // retried after the animation, not dropped
    }

    @Test func spaceKeyWithoutSkyLightNeverNotifies() {
        let h = Harness(); h.start()
        h.desk.spacesUnavailable = true
        h.spaceKeys.key(25, flags: .maskAlternate) // ⌥9
        h.settle()
        #expect(h.recorder.notices.isEmpty)
    }

    // MARK: - App Structure Tests (Unified Toolbar, Title Text, Electron, Focus Fallback)

    @Test func throwWindowWithUnifiedToolbar() {
        let (h, a, _, _) = setup()
        h.desk.updateQuirks(a) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, role: "AXToolbar")] }
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
    }

    @Test func throwWindowWithTitleText() {
        let (h, a, _, _) = setup()
        h.desk.updateQuirks(a) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0.2, to: 0.8, role: "AXStaticText")] }
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
    }

    @Test func throwElectronWindowWithGenericElement() {
        let (h, a, _, _) = setup()
        h.desk.updateQuirks(a) { $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, role: "AXGenericElement")] }
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
    }

    @Test func throwFallsBackToTrackedFocusedWindowWhenAXFocusedAppFails() {
        let (h, a, _, _) = setup()
        // Simulate AX focusedApplication failing (e.g. uncooperative app, timing glitch)
        h.desk.ax.focusedApplicationOverride = { nil }
        #expect((try? h.desk.ax.focusedApplication()) == nil)
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
    }

    @Test func throwFallsBackWhenAXFocusedWindowFails() {
        let (h, a, _, _) = setup()
        // Simulate AX focusedWindow(pid:) failing, falling back to windows(pid) or trackedFocusedRef
        h.desk.ax.focusedWindowOverride = { _ in nil }
        #expect((try? h.desk.ax.focusedWindow(pid: 100)) == nil)
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
    }

    @Test func throwBrowserWindowWithTabHoverPreview() {
        let (h, a, _, _) = setup()
        // Add a tab hover card / preview belonging to the browser (pid 100) at layer 0
        _ = h.desk.addWindow(pid: 100, id: 99, frame: rect(200, 32, 240, 80))
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
        #expect(h.desk.posted.contains(where: {
            if case .leftMouseDragged = $0 { return true }; return false
        }))
    }

    @Test func throwBrowserWindowWithTabsAcrossTitlebar() {
        let (h, a, _, _) = setup()
        // Tabs span top: 3..28 across the titlebar
        h.desk.updateQuirks(a) {
            $0.titlebarRegions = [FakeTitlebarRegion(from: 0, to: 1, top: 3, bottom: 28, role: "AXRadioButton")]
        }
        throwFocused(h, 2)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.throwFailures.isEmpty)
        #expect(h.desk.posted.contains(where: {
            if case .leftMouseDragged = $0 { return true }; return false
        }))
    }
}
