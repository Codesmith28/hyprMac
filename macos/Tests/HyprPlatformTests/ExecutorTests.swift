import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

@Suite struct ExecutorTests {
    @Test func exactCallSequence() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let (ex, events) = makeExecutor(desk)
        let target = rect(12, 37, 700, 600)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(desk.axCalls == [
            .setMessagingTimeout(100, 0.25), .frame(w), .enhancedUI(100),
            .setSize(w, target.size), .setPosition(w, target.origin), .setSize(w, target.size), .frame(w),
        ])
        #expect(events.all == [.landed(w, revision: 1, frame: target, skipped: false)])
        #expect(desk.frame(of: w) == target)
    }

    @Test func skipsWriteWhenAlreadyThere() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(12, 37, 700, 600))
        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, rect(12.3, 37, 700, 599.6))])
        #expect(ex.waitUntilIdle())
        #expect(!desk.axCalls.contains { $0.isWrite })
        #expect(events.all == [.landed(w, revision: 1, frame: rect(12, 37, 700, 600), skipped: true)])
    }

    /// Quirk 1: a minimum size is discovered from the read-back.
    @Test func minimumSizeDiscovered() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 400, height: 300)
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500), quirks: q)
        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, rect(0, 25, 300, 600))])
        #expect(ex.waitUntilIdle())
        // Height fit: reported as 0 ("unknown"); width exceeded: reported.
        #expect(events.all == [.minSizeDiscovered(w, CGSize(width: 400, height: 0))])
    }

    /// Quirk 2: display clamping is beaten by size → position → size.
    @Test func displayClampNeedsSizePositionSize() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.clampToDisplay = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(1200, 600, 200, 200), quirks: q)
        let target = rect(0, 25, 1440, 875)
        // Naive position-then-size would land small because the first size is clamped:
        let naive = desk.addWindow(pid: 100, id: 2, frame: rect(1200, 600, 200, 200), quirks: q)
        try? desk.ax.setSize(target.size, of: naive)
        try? desk.ax.setPosition(target.origin, of: naive)
        #expect(desk.frame(of: naive) != target)

        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: w) == target)
        #expect(events.all == [.landed(w, revision: 1, frame: target, skipped: false)])
    }

    @Test func displayClampOnMoveWithLargeWindow() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.clampToDisplay = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 1440, 875), quirks: q)
        let target = rect(720, 462, 720, 438)
        let (ex, _) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: w) == target)
    }

    /// Quirk 3: enhanced UI is switched off for the write and restored afterwards.
    @Test func enhancedUserInterfaceDisabledAndRestored() {
        let desk = makeDesk()
        desk.setEnhancedUI(pid: 100, true, slowDelay: 0.02, inaccuracy: 13)
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        // Without the dance, a size set lands inaccurately.
        let probe = desk.addWindow(pid: 100, id: 2, frame: rect(0, 25, 500, 500))
        try? desk.ax.setSize(CGSize(width: 600, height: 600), of: probe)
        #expect(desk.frame(of: probe)?.size == CGSize(width: 587, height: 587))

        desk.clearAXCalls()
        let (ex, events) = makeExecutor(desk)
        let target = rect(10, 40, 800, 700)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: w) == target)
        #expect(desk.enhancedUI(pid: 100))
        let calls = desk.axCalls
        let off = calls.firstIndex(of: .setEnhancedUI(100, false))!
        let on = calls.firstIndex(of: .setEnhancedUI(100, true))!
        let firstSize = calls.firstIndex(of: .setSize(w, target.size))!
        let lastFrame = calls.lastIndex(of: .frame(w))!
        #expect(off < firstSize && firstSize < on && on < lastFrame)
        #expect(events.all == [.landed(w, revision: 1, frame: target, skipped: false)])
    }

    @Test func enhancedUserInterfaceRestoredWhenWriteFails() {
        let desk = makeDesk()
        desk.setEnhancedUI(pid: 100, true)
        var q = FakeWindowQuirks(); q.closesOnWrite = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500), quirks: q)
        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, rect(0, 25, 600, 600))])
        #expect(ex.waitUntilIdle())
        #expect(desk.enhancedUI(pid: 100))
        #expect(events.all == [.windowGone(w)])
    }

    /// Quirk 4: a hung app never delays another app's writes (one serial queue per pid).
    @Test func hungAppDoesNotDelayOtherApps() {
        let desk = makeDesk()
        let hungWin = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        desk.addApp(pid: 200, bundleID: "com.example.ok")
        let okWin = desk.addWindow(pid: 200, id: 2, frame: rect(700, 25, 500, 500))
        desk.setHung(pid: 100, true, duration: 10) // each call blocks for the 0.25 s messaging timeout
        let (ex, events) = makeExecutor(desk)
        let start = ProcessInfo.processInfo.systemUptime
        ex.apply(revision: 1, placements: [(hungWin, rect(0, 25, 700, 875)), (okWin, rect(720, 25, 720, 875))])
        #expect(ex.waitUntilIdle(timeout: 10))
        let okAt = events.firstTime { $0.ref == okWin }!
        let hungAt = events.firstTime { $0.ref == hungWin }!
        #expect(okAt - start < 0.2)
        #expect(hungAt - start >= 0.7) // 3 attempts × 0.25 s
        #expect(events.all.contains(.failed(hungWin, .cannotComplete)))
        #expect(events.all.contains(.landed(okWin, revision: 1, frame: rect(720, 25, 720, 875), skipped: false)))
        #expect(desk.messagingTimeout(pid: 100) == 0.25)
    }

    @Test func applyReturnsImmediatelyEvenForHungApp() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        desk.setHung(pid: 100, true)
        let (ex, _) = makeExecutor(desk, retryDelays: [])
        let start = ProcessInfo.processInfo.systemUptime
        ex.apply(revision: 1, placements: [(w, rect(0, 25, 600, 600))])
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.05)
        #expect(ex.waitUntilIdle())
    }

    /// Quirk 5: the first K calls fail; the executor retries and lands.
    @Test func notReadyWindowRetriedUntilItLands() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.notReadyCalls = 2
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500), quirks: q)
        let (ex, events) = makeExecutor(desk)
        let target = rect(0, 25, 720, 875)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(events.all == [.landed(w, revision: 1, frame: target, skipped: false)])
        #expect(desk.frame(of: w) == target)
    }

    @Test func neverReadyWindowFailsAfterAllAttempts() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.notReadyCalls = 100
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500), quirks: q)
        let (ex, events) = makeExecutor(desk, retryDelays: [0.01, 0.01, 0.01])
        ex.apply(revision: 1, placements: [(w, rect(0, 25, 720, 875))])
        #expect(ex.waitUntilIdle())
        #expect(events.all == [.failed(w, .cannotComplete)])
        #expect(desk.axCalls.filter { $0 == .frame(w) }.count == 4)
    }

    /// Quirk 6: the window closes mid-write.
    @Test func windowClosingDuringWriteReportsGone() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.closesOnWrite = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500), quirks: q)
        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, rect(0, 25, 720, 875))])
        #expect(ex.waitUntilIdle())
        #expect(events.all == [.windowGone(w)])
        #expect(desk.frame(of: w) == nil)
    }

    /// Quirk 10: the app snaps back to its previous size.
    @Test func snapBackToSmallerSizeIsMismatch() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.snapsBack = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500), quirks: q)
        let (ex, events) = makeExecutor(desk)
        let target = rect(0, 25, 720, 875)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(events.all == [.mismatch(w, target: target, actual: rect(0, 25, 500, 500))])
    }

    @Test func snapBackToLargerSizeLooksLikeMinSize() {
        let desk = makeDesk()
        var q = FakeWindowQuirks(); q.snapsBack = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 900, 800), quirks: q)
        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 1, placements: [(w, rect(0, 25, 720, 875))])
        #expect(ex.waitUntilIdle())
        #expect(events.all == [.minSizeDiscovered(w, CGSize(width: 900, height: 0))])
    }

    /// Latest-wins: targets queued behind a busy pid queue collapse into one write.
    @Test func coalescesPendingTargets() {
        let desk = makeDesk()
        let busy = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let w = desk.addWindow(pid: 100, id: 2, frame: rect(0, 25, 500, 500))
        let (ex, events) = makeExecutor(desk)
        desk.setHung(pid: 100, true) // the first call blocks pid 100's queue for 0.25 s
        ex.apply(revision: 1, placements: [(busy, rect(0, 25, 600, 600))])
        ex.apply(revision: 2, placements: [(w, rect(0, 25, 610, 610))])
        ex.apply(revision: 3, placements: [(w, rect(0, 25, 620, 620))])
        ex.apply(revision: 4, placements: [(w, rect(0, 25, 630, 630))])
        Thread.sleep(forTimeInterval: 0.05)
        desk.setHung(pid: 100, false)
        #expect(ex.waitUntilIdle())
        let sizes = desk.axCalls.compactMap { c -> CGSize? in
            if case .setSize(let r, let s) = c, r == w { return s }
            return nil
        }
        #expect(sizes == [CGSize(width: 630, height: 630), CGSize(width: 630, height: 630)])
        #expect(ex.statistics.coalesced == 2)
        #expect(events.all.filter { $0.ref == w } == [.landed(w, revision: 4, frame: rect(0, 25, 630, 630), skipped: false)])
    }

    @Test func dropsStaleRevisions() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let (ex, _) = makeExecutor(desk)
        ex.apply(revision: 5, placements: [(w, rect(0, 25, 700, 700))])
        #expect(ex.waitUntilIdle())
        ex.apply(revision: 3, placements: [(w, rect(0, 25, 300, 300))])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: w) == rect(0, 25, 700, 700))
        #expect(ex.statistics.staleDropped == 1)
        // Equal revision (same plan re-sent) is accepted.
        ex.apply(revision: 5, placements: [(w, rect(0, 25, 710, 710))])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: w) == rect(0, 25, 710, 710))
    }

    @Test func staleCheckIsPerWindow() {
        let desk = makeDesk()
        let a = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let b = desk.addWindow(pid: 100, id: 2, frame: rect(0, 25, 500, 500))
        let (ex, _) = makeExecutor(desk)
        ex.apply(revision: 9, placements: [(a, rect(0, 25, 600, 600))])
        ex.apply(revision: 2, placements: [(b, rect(0, 25, 650, 650))])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: b) == rect(0, 25, 650, 650))
        #expect(ex.statistics.staleDropped == 0)
    }

    @Test func echoesOfOwnWritesAreRecognised() {
        let desk = makeDesk()
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let (ex, _) = makeExecutor(desk)
        let target = rect(100, 100, 800, 600)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        let now = desk.clock.now()
        #expect(ex.echo.isEcho(w, observedFrame: target, now: now + 0.5))
        // Intermediate frame after the first size write (old origin, new size).
        #expect(ex.echo.isEcho(w, observedFrame: rect(0, 25, 800, 600), now: now))
        #expect(!ex.echo.isEcho(w, observedFrame: rect(300, 300, 800, 600), now: now))
        #expect(!ex.echo.isEcho(w, observedFrame: target, now: now + 1.5))
    }

    /// Quirk 13: state for a relaunched app's old ref never leaks into the new ref.
    @Test func relaunchedWindowIsIndependent() {
        let desk = makeDesk()
        let old = desk.addWindow(pid: 100, id: 7, frame: rect(0, 25, 500, 500))
        let (ex, events) = makeExecutor(desk)
        ex.apply(revision: 10, placements: [(old, rect(0, 25, 600, 600))])
        #expect(ex.waitUntilIdle())
        let new = desk.relaunch(pid: 100, as: 101)[0]
        ex.forget(pid: 100)
        #expect(!ex.echo.isEcho(new, observedFrame: rect(0, 25, 600, 600), now: desk.clock.now()))
        ex.apply(revision: 3, placements: [(new, rect(0, 25, 300, 300))])
        ex.apply(revision: 4, placements: [(old, rect(0, 25, 200, 200))])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: new) == rect(0, 25, 300, 300))
        #expect(events.all.contains(.windowGone(old)))
    }

    @Test func movingAcrossDisplaysWithNegativeCoordinates() {
        let desk = makeDesk()
        desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080), visibleFrame: rect(-1920, -155, 1920, 1055))
        var q = FakeWindowQuirks(); q.clampToDisplay = true
        let w = desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 600, 400), quirks: q)
        let (ex, _) = makeExecutor(desk)
        let target = rect(-1908, -143, 1896, 1031)
        ex.apply(revision: 1, placements: [(w, target)])
        #expect(ex.waitUntilIdle())
        #expect(desk.frame(of: w) == target)
        #expect(desk.space(of: w) == desk.spaces.activeSpace(display: 2))
    }
}

@Suite struct EchoFilterTests {
    let r = WindowRef(pid: 1, windowID: 1)

    @Test func matchesWithinToleranceAndWindow() {
        let f = EchoFilter()
        f.record(r, frame: rect(0, 0, 100, 100), at: 10)
        #expect(f.isEcho(r, observedFrame: rect(1.9, -2, 101, 98.5), now: 10.9))
        #expect(!f.isEcho(r, observedFrame: rect(2.5, 0, 100, 100), now: 10.1))
        #expect(!f.isEcho(r, observedFrame: rect(0, 0, 100, 100), now: 11.2))
        #expect(!f.isEcho(WindowRef(pid: 2, windowID: 1), observedFrame: rect(0, 0, 100, 100), now: 10))
    }

    @Test func forgetClearsRecords() {
        let f = EchoFilter()
        f.record(r, frame: rect(0, 0, 100, 100), at: 10)
        f.forget(r)
        #expect(!f.isEcho(r, observedFrame: rect(0, 0, 100, 100), now: 10))
        f.record(r, frame: rect(0, 0, 100, 100), at: 10)
        f.forget(pid: 1)
        #expect(!f.isEcho(r, observedFrame: rect(0, 0, 100, 100), now: 10))
    }

    @Test func oldRecordsArePruned() {
        let f = EchoFilter(window: 1, tolerance: 2)
        f.record(r, frame: rect(0, 0, 100, 100), at: 0)
        f.record(r, frame: rect(500, 0, 100, 100), at: 5)
        #expect(!f.isEcho(r, observedFrame: rect(0, 0, 100, 100), now: 5))
        #expect(f.isEcho(r, observedFrame: rect(500, 0, 100, 100), now: 5))
    }
}
