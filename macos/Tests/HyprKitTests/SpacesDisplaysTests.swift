import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

@Suite struct SpacesDisplaysTests {
    @Test func perSpaceTreesSurviveSpaceSwitch() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        let c = h.desk.addWindow(pid: 100, id: 3, frame: rect(50, 50, 400, 300), space: h.s2)
        h.desk.setActiveSpace(h.s2, display: 1); h.settle()
        #expect(h.frame(c) == root)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf) // untouched while invisible
        let d = h.open(4)
        #expect(h.frame(c) == leftHalf && h.frame(d) == rightHalf)
        h.desk.setActiveSpace(h.s1, display: 1); h.settle()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.tiled(h.s2) == 2)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
    }

    @Test func twoDisplaysIncludingNegativeCoordinates() {
        let h = Harness()
        let ids = h.desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080), visibleFrame: rect(-1920, -155, 1920, 1055))
        h.start()
        let left = h.open(1, frame: rect(-1800, -100, 600, 400))
        let right = h.open(2, frame: rect(200, 200, 400, 300))
        #expect(h.frame(left) == rect(-1908, -143, 1896, 1031))
        #expect(h.frame(right) == root)
        let left2 = h.open(3, frame: rect(-1500, 0, 600, 400))
        #expect(h.frame(left) == rect(-1908, -143, 944, 1031))
        #expect(h.frame(left2) == rect(-956, -143, 944, 1031))
        #expect(h.tiled(ids[0]) == 2)
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func spaceSwitchOnOneDisplayLeavesTheOtherAlone() {
        let h = Harness()
        let ids = h.desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080), visibleFrame: rect(-1920, -155, 1920, 1055), userSpaces: 2)
        h.start()
        let left = h.open(1, frame: rect(-1800, -100, 600, 400))
        let right = h.open(2)
        h.desk.setActiveSpace(h.s2, display: 1); h.settle()
        #expect(h.frame(left) == rect(-1908, -143, 1896, 1031))
        #expect(h.tiled(ids[0]) == 1)
        #expect(h.c.testSpaceOf(h.id(right)!) == h.s1)
    }
}
