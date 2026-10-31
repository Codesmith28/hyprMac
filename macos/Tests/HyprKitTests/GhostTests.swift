import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Minimized / hidden / fullscreen windows keep a ghost slot and return to the same rectangle.
@Suite struct GhostTests {
    @Test func minimizeReflowsAndRestoresSameRect() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        let before = [a, b, c].map { h.frame($0)! }
        h.desk.setMinimized(b, true); h.settle()
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(c) == rightHalf)
        #expect(h.tiled(h.s1) == 2)
        h.desk.setMinimized(b, false); h.settle()
        #expect([a, b, c].map { h.frame($0)! } == before)
    }

    @Test func hiddenAppRestoresSameRect() {
        let h = Harness(); h.start()
        let a = h.open(1)
        h.desk.addApp(pid: 200, bundleID: "com.example.term")
        let b = h.open(2, pid: 200)
        let c = h.open(3)
        let before = [a, b, c].map { h.frame($0)! }
        h.desk.setAppHidden(pid: 200, true); h.settle()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(c) == rightHalf)
        h.desk.setAppHidden(pid: 200, false); h.settle()
        #expect([a, b, c].map { h.frame($0)! } == before)
    }

    @Test func fullscreenRestoresSameRect() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.desk.setFullscreen(b, true); h.settle()              // reconcile of the fullscreen Space
        let fs = h.desk.spaces.activeSpace(display: 1)
        #expect(fs != h.s1)
        h.desk.setActiveSpace(h.s1, display: 1); h.settle()   // swipe back to the desktop
        #expect(h.frame(a) == root)
        #expect(h.tiled(h.s1) == 1)
        #expect(h.c.testSpaceOf(h.id(b)!) == h.s1)            // ghost stays on its user Space
        h.desk.setActiveSpace(fs, display: 1)
        h.desk.setFullscreen(b, false); h.settle()
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func appTerminationPurgesGhosts() {
        let h = Harness(); h.start()
        let a = h.open(1)
        h.desk.addApp(pid: 200, bundleID: "com.example.term")
        let b = h.open(2, pid: 200)
        let bid = h.id(b)!
        h.desk.setMinimized(b, true); h.settle()
        #expect(h.c.testSpaceOf(bid) == h.s1)                  // ghost slot
        h.desk.terminate(pid: 200); h.settle()
        #expect(h.c.testSpaceOf(bid) == nil)
        #expect(h.frame(a) == root)
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func inferredGhostOnAnotherSpaceIsNotStolen() {
        let h = Harness(); h.start()
        let b = h.open(2)
        let a = h.desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 500, 400), space: h.s2)
        h.desk.setActiveSpace(h.s2, display: 1); h.settle()
        #expect(h.frame(a) == root)
        let aid = h.id(a)!
        h.desk.setMinimized(a, true); h.settle()
        h.desk.setActiveSpace(h.s1, display: 1); h.settle()
        // A is minimized with no Space info; it must stay Space 2's ghost.
        #expect(h.c.testSpaceOf(aid) == h.s2)
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(b) == root)
        h.desk.setActiveSpace(h.s2, display: 1)
        h.desk.setMinimized(a, false); h.settle()
        #expect(h.frame(a) == root)
        #expect(h.tiled(h.s2) == 1)
    }
}
