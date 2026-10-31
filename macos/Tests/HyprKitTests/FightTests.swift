import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Min sizes, windows that fight their tile, our own echoes and user drags.
@Suite struct FightTests {
    @Test func minSizeDiscoveredTriggersRelayout() {
        let h = Harness(); h.start()
        let a = h.open(1)
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 900, height: 0)
        let b = h.open(2, quirks: q)
        #expect(h.frame(a) == rect(12, 37, 508, 851))
        #expect(h.frame(b) == rect(528, 37, 900, 851))
        // Stable afterwards: one more reconcile is one more plan, no loop.
        let plans = h.c.testPlanCount()
        h.reconcile()
        #expect(h.c.testPlanCount() == plans + 1)
        #expect(h.frame(b) == rect(528, 37, 900, 851))
        #expect(h.c.testUncooperative().isEmpty)
    }

    @Test func snapBackWindowFloatsAfterFightLimitWithoutLooping() {
        let h = Harness(); h.start()
        let a = h.open(1)
        let plansBefore = h.c.testPlanCount()
        var q = FakeWindowQuirks(); q.snapsBack = true
        let b = h.open(2, quirks: q)
        let bid = h.id(b)!
        #expect(h.c.testUncooperative() == [bid])
        #expect(h.frame(a) == root)                         // B floated, A took the space back
        #expect(h.tiled(h.s1) == 1)
        let plans = h.c.testPlanCount() - plansBefore
        #expect(plans >= 3 && plans <= 8, "plans: \(plans)")
        // Settled for good: nothing else is planned without a new event.
        let settled = h.c.testPlanCount()
        h.settle()
        #expect(h.c.testPlanCount() == settled)
    }

    @Test func retileAllForgivesUncooperativeWindows() {
        let h = Harness(); h.start()
        let a = h.open(1)
        var q = FakeWindowQuirks(); q.snapsBack = true
        let b = h.open(2, quirks: q)
        #expect(!h.c.testUncooperative().isEmpty)
        h.desk.updateQuirks(b) { $0.snapsBack = false }
        h.c.retileAll(); h.settle()
        #expect(h.c.testUncooperative().isEmpty)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
    }

    @Test func echoEventsAreIgnored() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        let plans = h.c.testPlanCount()
        h.send(.window(.moved, pid: 100, window: a))
        h.send(.window(.resized, pid: 100, window: b))
        #expect(h.c.testPlanCount() == plans)
        #expect(h.c.testUncooperative().isEmpty)
    }

    @Test func userResizeSnapsBack() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        let plans = h.c.testPlanCount()
        h.desk.setFrame(a, rect(12, 37, 600, 851))
        h.send(.window(.resized, pid: 100, window: a))
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        #expect(h.c.testPlanCount() == plans + 1)
        #expect(h.c.testUncooperative().isEmpty)
    }

    @Test func dragDefersRetileThenSnapsBack() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.send(.userDragBegan(CGPoint(x: 100, y: 45)))
        h.desk.setFrame(a, rect(300, 300, 704, 851))
        h.send(.window(.moved, pid: 100, window: a))
        let plans = h.c.testPlanCount()
        h.reconcile() // must not fight the user mid-drag
        h.open(3, focus: false)
        #expect(h.c.testPlanCount() == plans)
        #expect(h.frame(a) == rect(300, 300, 704, 851))
        h.send(.userDragEnded(CGPoint(x: 400, y: 345)))
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rect(724, 37, 704, 421.5))
        #expect(h.c.testUncooperative().isEmpty)
    }

    @Test func lateMovesAfterDragAreNotFights() {
        let h = Harness(); h.start()
        let a = h.open(1); h.open(2)
        h.send(.userDragBegan(.zero))
        h.send(.userDragEnded(.zero))
        for i in 0..<4 {
            h.desk.setFrame(a, rect(CGFloat(300 + i), 300, 704, 851))
            h.send(.window(.moved, pid: 100, window: a))
        }
        #expect(h.c.testUncooperative().isEmpty)
        #expect(h.frame(a) == leftHalf)
    }

    @Test func repeatedSelfResizesFloatTheWindow() {
        let h = Harness(); h.start()
        let a = h.open(1); let b = h.open(2)
        for i in 0..<3 {
            h.desk.setFrame(b, rect(724, 37, CGFloat(400 + 60 * i), 851))
            h.send(.window(.resized, pid: 100, window: b))
        }
        #expect(h.c.testUncooperative() == [h.id(b)!])
        #expect(h.frame(a) == root)
    }
}
