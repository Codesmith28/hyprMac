import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

@Suite struct RobustnessTests {
    @Test func unresolvedWindowKeepsItsTile() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.desk.updateQuirks(b) { $0.notReadyCalls = 2 } // the next discovery can't read B
        h.reconcile()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func lateWindowIsTiledOnRetry() {
        let h = Harness(); h.start()
        let a = h.open(1)
        var q = FakeWindowQuirks(); q.notReadyCalls = 3 // not AX-ready for the first round
        let b = h.open(2, quirks: q)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func hungAppDoesNotBlockAnotherApp() {
        let h = Harness(); h.start()
        let a = h.open(1)
        h.desk.addApp(pid: 200, bundleID: "com.example.stuck")
        let stuck = h.open(2, pid: 200)
        h.desk.setHung(pid: 200, true, duration: 30)
        let start = Date()
        let b = h.desk.addWindow(pid: 100, id: 3, frame: rect(200, 200, 400, 300))
        h.desk.focus(b)
        var landed: TimeInterval?
        while Date().timeIntervalSince(start) < 5 {
            if h.frame(b) == rect(724, 466.5, 704, 421.5) { landed = Date().timeIntervalSince(start); break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(landed != nil && landed! < 2.5)
        h.settle()
        #expect(h.tiled(h.s1) == 3) // the hung app's window kept its tile
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(stuck) == rightHalf) // the hung app never applied its new tile
    }

    @Test func windowIdReuseAfterRelaunch() {
        let h = Harness(); h.start()
        let a = h.open(7)
        let oldID = h.id(a)!
        let fresh = h.desk.relaunch(pid: 100, as: 101)
        h.settle()
        #expect(fresh.map(\.windowID) == [7])
        let newID = h.id(fresh[0])!
        #expect(newID != oldID)
        #expect(newID & 0xFFFF_FFFF == 7)
        #expect(h.c.testSpaceOf(oldID) == nil)
        #expect(h.c.testSpaceOf(newID) == h.s1)
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(fresh[0]) == root)
        let b = h.open(8, pid: 101)
        #expect(h.frame(fresh[0]) == leftHalf && h.frame(b) == rightHalf)
    }

    @Test func windowClosingDuringWriteReflows() {
        let h = Harness(); h.start()
        let a = h.open(1)
        var q = FakeWindowQuirks(); q.closesOnWrite = true
        h.open(2, quirks: q)
        #expect(h.frame(a) == root)
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func screenParametersChangeRetiles() {
        let h = Harness(); h.start()
        let a = h.open(1)
        h.desk.setFrame(a, rect(0, 0, 100, 100))
        h.send(.screenParametersChanged)
        #expect(h.frame(a) == root)
    }
}
