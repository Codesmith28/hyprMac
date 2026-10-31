import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Hyprland-style user resize: a drag that changes a tiled window's size is adopted on mouse-up.
@Suite struct UserResizeTests {
    @Test func draggingTheSharedEdgeAdoptsTheNewSize() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.send(.userDragBegan(CGPoint(x: 714, y: 400)))
        h.desk.setFrame(a, rect(12, 37, 904, 851))
        h.send(.window(.resized, pid: 100, window: a))
        h.send(.userDragEnded(CGPoint(x: 914, y: 400)))
        let fa = h.frame(a)!, fb = h.frame(b)!
        #expect(abs(fa.width - 904) <= 1)
        #expect(abs(fb.minX - (fa.maxX + 8)) <= 1)
        #expect(fb.width < 704)
        #expect(abs(fb.maxX - 1428) <= 1)
        #expect(h.c.testFightCount(h.id(a)!) == 0)
        #expect(h.c.testUncooperative().isEmpty)
        // Persists: a later reconcile keeps the ratio.
        h.reconcile()
        #expect(abs(h.frame(a)!.width - 904) <= 1)
    }

    @Test func titlebarMoveWithSameSizeSnapsBack() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.send(.userDragBegan(CGPoint(x: 100, y: 45)))
        h.desk.setFrame(a, rect(300, 300, 704, 851))
        h.send(.window(.moved, pid: 100, window: a))
        h.send(.userDragEnded(CGPoint(x: 400, y: 345)))
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        #expect(h.c.testFightCount(h.id(a)!) == 0)
    }

    @Test func resizingTheOuterScreenEdgeSnapsBack() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.send(.userDragBegan(CGPoint(x: 14, y: 400)))
        h.desk.setFrame(a, rect(0, 37, 716, 851)) // left edge on the screen boundary: no split
        h.send(.window(.resized, pid: 100, window: a))
        h.send(.userDragEnded(CGPoint(x: 0, y: 400)))
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func selfResizeWithoutDragStillFloatsAfterThreeFights() {
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
