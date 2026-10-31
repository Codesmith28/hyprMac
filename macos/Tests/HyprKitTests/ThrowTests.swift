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
        #expect(h.recorder.notices.isEmpty)
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

    @Test func throwTimeoutNotifiesAndKeepsLayout() {
        let (h, a, b, _) = setup()
        h.desk.nativeSwitchEnabled = false
        throwFocused(h, 2)
        #expect(h.recorder.throwFailures.count == 1)
        #expect(h.recorder.throwFailures.first?.contains("Switch to Desktop 2") == true)
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.frame(b) == leftHalf && h.frame(a) == rightHalf)
        #expect(h.desk.posted.suffix(2).first == .leftMouseUp(CGPoint(x: 900, y: 45)))
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
        #expect(h.recorder.notices.isEmpty)
    }

    @Test func throwDuringTransitionIsRetriedAfterSettling() {
        let (h, a, _, _) = setup()
        h.send(.activeSpaceChanged) // a transition just started
        h.c.throwFocusedWindow(toSpace: 2)
        h.c.queue.sync {}
        h.desk.clock.advance(by: 1) // the animation finishes before the retry fires
        h.settle()
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.recorder.notices.isEmpty)
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
        #expect(h.recorder.notices.count == 1)
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
}
