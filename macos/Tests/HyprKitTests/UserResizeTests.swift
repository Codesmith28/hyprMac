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

    @Test func draggingTiledWindowTitlebarOntoAnotherTileSwapsThem() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)

        h.send(.userDragBegan(CGPoint(x: 100, y: 45)))
        // Move window `a` so its center is inside `rightHalf`
        h.desk.setFrame(a, rect(800, 37, 704, 851))
        h.send(.window(.moved, pid: 100, window: a))
        h.send(.userDragEnded(CGPoint(x: 800, y: 45)))

        #expect(h.frame(a) == rightHalf)
        #expect(h.frame(b) == leftHalf)
        #expect(h.c.testFightCount(h.id(a)!) == 0)

        // Persists across reconciles
        h.reconcile()
        #expect(h.frame(a) == rightHalf)
        #expect(h.frame(b) == leftHalf)
    }

    @Test func draggingFloatingWindowKeepsNewPosition() {
        let h = Harness(); h.start()
        h.c.queue.sync {}
        _ = h.open(1)
        let b = h.open(2)
        h.desk.focus(b)
        h.hotkeys.pressToggleFloat()
        h.settle()
        #expect(h.c.testFloatOverride()[h.id(b)!] == true)

        let draggedFrame = rect(350, 250, 400, 300)
        h.send(.userDragBegan(CGPoint(x: 520, y: 312)))
        h.desk.setFrame(b, draggedFrame)
        h.send(.window(.moved, pid: 100, window: b))
        h.send(.userDragEnded(CGPoint(x: 600, y: 350)))

        #expect(h.frame(b) == draggedFrame)
        #expect(h.c.testFirstSeenFrame(h.id(b)!) == draggedFrame)

        h.reconcile()
        #expect(h.frame(b) == draggedFrame)
        #expect(h.c.testFirstSeenFrame(h.id(b)!) == draggedFrame)
    }

    @Test func draggingNativelyFloatingWindowKeepsNewPosition() {
        let h = Harness(); h.start()
        _ = h.open(1)
        let b = h.open(2, resizable: false)
        h.settle()
        #expect(h.c.testTiledCount(space: h.s1) == 1)

        let draggedFrame = rect(400, 200, 300, 200)
        h.send(.userDragBegan(CGPoint(x: 250, y: 250)))
        h.desk.setFrame(b, draggedFrame)
        h.send(.window(.moved, pid: 100, window: b))
        h.send(.userDragEnded(CGPoint(x: 450, y: 250)))

        #expect(h.frame(b) == draggedFrame)
        #expect(h.c.testFirstSeenFrame(h.id(b)!) == draggedFrame)

        h.reconcile()
        #expect(h.frame(b) == draggedFrame)
        #expect(h.c.testFirstSeenFrame(h.id(b)!) == draggedFrame)
    }
}
