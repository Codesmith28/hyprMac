import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Exact geometry with the real engine: outer gap 12 on the usable rect, inner gap 8 per split.
@Suite struct LayoutTests {
    @Test func oneWindowFillsUsableMinusOuterGap() {
        let h = Harness(); h.start()
        let a = h.open(1)
        #expect(h.frame(a) == root)
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func twoWindowsSplitAlongLongerAxis() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        #expect(h.frame(b)!.minX - h.frame(a)!.maxX == 8)
    }

    @Test func threeWindowsDwindle() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rect(724, 37, 704, 421.5))
        #expect(h.frame(c) == rect(724, 466.5, 704, 421.5))
        #expect(h.frame(c)!.minY - h.frame(b)!.maxY == 8)
    }

    @Test func fourWindowsDwindle() {
        let h = Harness(); h.start()
        let ws = (1...4).map { h.open(CGWindowID($0)) }
        #expect(ws.map { h.frame($0)! } == [
            leftHalf, rect(724, 37, 704, 421.5), rect(724, 466.5, 348, 421.5), rect(1080, 466.5, 348, 421.5),
        ])
    }

    @Test func fiveWindowsDwindleWithExactGaps() {
        let h = Harness(); h.start()
        let ws = (1...5).map { h.open(CGWindowID($0)) }
        let f = ws.map { h.frame($0)! }
        #expect(f == [
            leftHalf, rect(724, 37, 704, 421.5), rect(724, 466.5, 348, 421.5),
            rect(1080, 466.5, 348, 206.75), rect(1080, 681.25, 348, 206.75),
        ])
        // Tiles cover the root exactly once, minus the inner gaps.
        let area: CGFloat = f.reduce(0) { $0 + $1.width * $1.height }
        let splitLengths: [CGFloat] = [851, 704, 421.5, 348] // length of each split's gap
        let gaps: CGFloat = splitLengths.reduce(0) { $0 + 8 * $1 }
        let total: CGFloat = root.width * root.height
        #expect(abs(area + gaps - total) < 0.001)
        for (i, x) in f.enumerated() { for y in f[(i + 1)...] { #expect(!x.intersects(y) || x.intersection(y).isEmpty) } }
        #expect(f.allSatisfy { root.contains($0) })
    }

    @Test func dwindleFollowsFocus() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(a); h.settle()
        let c = h.open(3, focus: false)
        #expect(h.frame(a) == rect(12, 37, 704, 421.5))
        #expect(h.frame(c) == rect(12, 466.5, 704, 421.5))
        #expect(h.frame(b) == rightHalf)
    }

    @Test func closingWindowReflows() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        h.desk.closeWindow(c); h.settle()
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        h.desk.closeWindow(a); h.settle()
        #expect(h.frame(b) == root)
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func closingMiddleOfFiveCollapsesSibling() {
        let h = Harness(); h.start()
        let ws = (1...5).map { h.open(CGWindowID($0)) }
        h.desk.closeWindow(ws[3]); h.settle()
        #expect(h.frame(ws[4]) == rect(1080, 466.5, 348, 421.5))
        #expect(h.tiled(h.s1) == 4)
    }

    @Test func floatingAndDialogWindowsAreNotTiled() {
        let h = Harness(); h.start()
        let a = h.open(1)
        let fixed = h.open(2, frame: rect(300, 300, 300, 200), resizable: false)
        let dialog = h.desk.addWindow(pid: 100, id: 3, frame: rect(400, 400, 300, 200), subrole: "AXDialog")
        h.settle()
        #expect(h.frame(a) == root)
        #expect(h.frame(fixed) == rect(300, 300, 300, 200))
        #expect(h.frame(dialog) == rect(400, 400, 300, 200))
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func nativeTabsCountAsOneTile() {
        let h = Harness(); h.start()
        let a = h.open(1)
        let tabs = h.desk.addTabs(pid: 100, ids: [10, 11, 12], frame: rect(300, 300, 500, 400), selected: 0)
        h.desk.focus(tabs[0]); h.settle()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(tabs.allSatisfy { h.frame($0) == rightHalf }) // tabs share one frame
    }

    @Test func preExistingSideBySideWindowsPreserveSpatialArrangementWhenLeftIsFrontmost() {
        let h = Harness()
        let a = h.desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 400, 600))
        let b = h.desk.addWindow(pid: 100, id: 2, frame: rect(600, 100, 400, 600))
        h.desk.focus(a)
        h.start()
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func preExistingSideBySideWindowsPreserveSpatialArrangementWhenRightIsFrontmost() {
        let h = Harness()
        let a = h.desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 400, 600))
        let b = h.desk.addWindow(pid: 100, id: 2, frame: rect(600, 100, 400, 600))
        h.desk.focus(b)
        h.start()
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func preExistingVerticallyStackedWindowsPreserveSpatialArrangement() {
        let h = Harness()
        let top = h.desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 600, 300))
        let bottom = h.desk.addWindow(pid: 100, id: 2, frame: rect(100, 500, 600, 300))
        h.desk.focus(bottom)
        h.start()
        #expect(h.frame(top) == leftHalf)
        #expect(h.frame(bottom) == rightHalf)
    }
}
