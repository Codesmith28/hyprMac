import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Regression tests for the core review's coordinator findings (C2, C3, C4, C6, C7).
@Suite struct HardeningTests {
    /// C2: two windows of min width 800 can't share 1408 pt. The same report must not re-plan
    /// forever (before the fix `testSettle` never returned).
    @Test func unsatisfiableMinSizesDoNotLoop() {
        let h = Harness(); h.start()
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 800, height: 0)
        let a = h.open(1, quirks: q)
        let before = h.c.testPlanCount()
        let b = h.open(2, quirks: q)
        let plans = h.c.testPlanCount() - before
        #expect(plans <= 4, "plans: \(plans)")
        // Proportional split of the unsatisfiable minimums; the windows sit at their minimum.
        #expect(h.frame(a)?.width == 800 && h.frame(b)?.width == 800)
        let settled = h.c.testPlanCount()
        h.settle()
        #expect(h.c.testPlanCount() == settled)
    }

    /// C2: a repeated identical report is ignored; a larger one re-plans once.
    @Test func onlyChangedMinSizeReportsRelayout() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        let ex = GeometryExecutor(ax: h.desk.ax)
        let plans = h.c.testPlanCount()
        h.c.geometryExecutor(ex, didReport: .minSizeDiscovered(b, CGSize(width: 900, height: 0))); h.settle()
        #expect(h.c.testPlanCount() == plans + 1)
        #expect(h.frame(a) == rect(12, 37, 508, 851))
        h.c.geometryExecutor(ex, didReport: .minSizeDiscovered(b, CGSize(width: 900, height: 0))); h.settle()
        h.c.geometryExecutor(ex, didReport: .minSizeDiscovered(b, CGSize(width: 0, height: 0))); h.settle()
        #expect(h.c.testPlanCount() == plans + 1)
    }

    /// C3: "Displays have separate Spaces" off — both displays report the same Space id.
    @Test func sharedSpaceIdAcrossDisplaysKeepsSeparateTrees() {
        let h = Harness()
        h.desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080), visibleFrame: rect(-1920, -155, 1920, 1055))
        h.desk.setActiveSpace(h.s1, display: 2) // one shared Space spanning both displays
        h.start()
        let a = h.open(1)
        let l1 = h.open(2, frame: rect(-1800, -100, 600, 400), space: h.s1)
        let l2 = h.open(3, frame: rect(-1500, 0, 600, 400), space: h.s1)
        let id1 = Coordinator.perDisplaySpaceID(space: h.s1, display: 1)
        let id2 = Coordinator.perDisplaySpaceID(space: h.s1, display: 2)
        #expect(id1 != id2 && id1 >> 62 == 3 && id2 >> 62 == 3)
        #expect(h.c.testActiveSpaces() == [id1, id2])
        for _ in 0..<3 { h.reconcile() } // no thrash between the two displays' snapshots
        #expect(h.tiled(id1) == 1 && h.tiled(id2) == 2)
        #expect(h.frame(a) == root)
        #expect(h.frame(l1) == rect(-1908, -143, 944, 1031))
        #expect(h.frame(l2) == rect(-956, -143, 944, 1031))
        h.desk.setMinimized(l1, true); h.settle()
        #expect(h.frame(l2) == rect(-1908, -143, 1896, 1031))
        h.desk.setMinimized(l1, false); h.settle()
        #expect(h.frame(l1) == rect(-1908, -143, 944, 1031))
        #expect(h.frame(a) == root)
    }

    @Test func distinctSpacesKeepNativeIds() {
        let h = Harness()
        let ids = h.desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080))
        h.start()
        #expect(h.c.testActiveSpaces() == [h.s1, ids[0]])
        #expect(Coordinator.perDisplaySpaceID(space: 4, display: 1) == Coordinator.perDisplaySpaceID(space: 4, display: 1))
        #expect(Coordinator.perDisplaySpaceID(space: 4, display: 1) != SyntheticSpaces.id(for: 1))
    }

    /// C4: per-window bookkeeping shrinks again when windows close or apps quit.
    @Test func bookkeepingIsPrunedOnCloseAndQuit() {
        let h = Harness(); h.start()
        let ws = (1...3).map { h.open(CGWindowID($0)) }
        #expect(h.c.testTrackedStateCount() == (3, 3, 3))
        h.desk.closeWindow(ws[0]); h.desk.closeWindow(ws[1]); h.settle()
        #expect(h.c.testTrackedStateCount() == (1, 1, 1))
        h.desk.terminate(pid: 100); h.settle()
        #expect(h.c.testTrackedStateCount() == (0, 0, 0))
    }

    /// C7: a window closed while minimized drops its ghost (AX destroyed).
    @Test func closingMinimizedWindowDropsGhost() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        let bid = h.id(b)!
        h.desk.setMinimized(b, true); h.settle()
        #expect(h.c.testSpaceOf(bid) == h.s1)
        h.desk.closeWindow(b); h.settle()
        #expect(h.c.testSpaceOf(bid) == nil)
        #expect(h.frame(a) == root)
        let c = h.open(3) // takes the right half fresh; no stale ghost interferes
        #expect(h.frame(c) == rightHalf)
    }

    /// C7: `windowGone` from the executor forgets the engine window too.
    @Test func windowGoneForgetsEngineWindow() {
        let h = Harness(); h.start()
        h.open(1)
        var q = FakeWindowQuirks(); q.closesOnWrite = true
        h.desk.eventHandler = nil // no AX destroyed notification: only the executor's report
        let b = h.desk.addWindow(pid: 100, id: 2, frame: rect(300, 300, 400, 300), quirks: q)
        h.desk.focus(b)
        h.reconcile()
        #expect(h.id(b) == nil)
        #expect(h.c.testTrackedStateCount().states == 1)
    }

    /// C6: a min-size report for a window on an invisible Space waits for that Space's next reconcile.
    @Test func minSizeOnInvisibleSpaceWaitsForReconcile() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.desk.setActiveSpace(h.s2, display: 1); h.settle()
        let plans = h.c.testPlanCount()
        h.c.geometryExecutor(GeometryExecutor(ax: h.desk.ax), didReport: .minSizeDiscovered(b, CGSize(width: 900, height: 0)))
        h.settle()
        #expect(h.c.testPlanCount() == plans)
        #expect(h.frame(a) == leftHalf)
        h.desk.setActiveSpace(h.s1, display: 1); h.settle()
        #expect(h.frame(a) == rect(12, 37, 508, 851))
        #expect(h.frame(b) == rect(528, 37, 900, 851))
    }
}
