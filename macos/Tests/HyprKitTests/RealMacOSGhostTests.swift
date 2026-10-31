import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Regression tests for what the real-macOS E2E (run 1) showed, modelled in `FakeDesktop`:
/// - a minimized standard window reports subrole "AXDialog" (the fake does so by default);
/// - a window entering fullscreen first drops out of AX's list and has no Space, then reports fullscreen.
/// Layout used: A left, B top-right, C bottom-right. B must come back top-right, not swapped with C.
@Suite struct RealMacOSGhostTests {
    @Test func minimizedWindowReportingDialogKeepsItsSlot() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        let before = [a, b, c].map { h.frame($0)! }
        #expect(before[1].minY < before[2].minY) // B above C
        h.desk.setMinimized(b, true); h.settle()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.c.testSpaceOf(h.id(b)!) == h.s1) // ghost, not forgotten
        h.desk.setMinimized(b, false); h.settle()
        #expect([a, b, c].map { h.frame($0)! } == before)
    }

    @Test func fullscreenLimboThenFullscreenRestoresExactSlot() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        let before = [a, b, c].map { h.frame($0)! }
        let bid = h.id(b)!
        // B leaves AX's list and has no Space; a reconcile lands in that window.
        h.desk.setFullscreenTransition(b, true)
        h.c.queue.sync { h.c.reconcileNow() }
        #expect(h.c.testSpaceOf(bid) == h.s1) // kept as a ghost, not forgotten
        #expect(h.tiled(h.s1) == 2)
        h.desk.setFullscreen(b, true); h.settle()          // now on its fullscreen Space
        let fs = h.desk.spaces.activeSpace(display: 1)
        h.desk.setActiveSpace(h.s1, display: 1); h.settle()
        #expect(h.c.testSpaceOf(bid) == h.s1)
        h.desk.setActiveSpace(fs, display: 1)
        h.desk.setFullscreen(b, false); h.settle()
        #expect([a, b, c].map { h.frame($0)! } == before)
    }

    @Test func windowMissingWithoutASpaceIsForgottenAfterTheGrace() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        let bid = h.id(b)!
        h.desk.eventHandler = nil // closed without any AX destroyed notification
        h.desk.setFullscreenTransition(b, true)
        h.c.queue.sync { h.c.reconcileNow() }
        #expect(h.c.testSpaceOf(bid) == h.s1)             // still held during the grace
        h.desk.clock.advance(by: Coordinator.limboGrace + 1)
        h.c.queue.sync { h.c.reconcileNow() }
        h.settle()
        #expect(h.c.testSpaceOf(bid) == nil)
        #expect(h.frame(a) == root)
    }
}
