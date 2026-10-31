import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// Hyprland-style min-size accommodation: siblings shrink so a window that refuses its tile gets
/// its minimum, recursively up the tree; unsatisfiable cases converge.
@Suite struct MinSizeTests {
    private func noOverlap(_ frames: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for i in frames.indices {
            for j in frames.indices where j > i {
                let inter = frames[i].intersection(frames[j])
                #expect(inter.isNull || inter.width * inter.height < 1, "overlap \(frames[i]) / \(frames[j])",
                        sourceLocation: sourceLocation)
            }
        }
    }

    private func threeWindows(exposed: Bool) -> (Harness, [Ref], Int) {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 900, height: 600); q.exposesMinSize = exposed
        let before = h.c.testPlanCount()
        let c = h.open(3, quirks: q)
        return (h, [a, b, c], h.c.testPlanCount() - before)
    }

    @Test func neighboursShrinkForAWindowMinimumOnBothAxes() {
        let (h, w, plans) = threeWindows(exposed: false)
        let c = h.frame(w[2])!
        #expect(c.width >= 900 && c.height >= 600, "\(c)")
        #expect(h.frame(w[0]) == rect(12, 37, 508, 851))
        #expect(h.frame(w[1]) == rect(528, 37, 900, 243))
        #expect(c == rect(528, 288, 900, 600))
        noOverlap(w.compactMap { h.frame($0) })
        // Exact counts depend on how debounced events batch; convergence is the real property.
        #expect(plans <= 4, "plans: \(plans)")
        let settled = h.c.testPlanCount()
        h.settle()
        #expect(h.c.testPlanCount() == settled)
    }

    @Test func discoveryHintAvoidsTheFailedWrite() {
        let (h, w, plans) = threeWindows(exposed: true)
        #expect(h.frame(w[2]) == rect(528, 288, 900, 600))
        #expect(h.frame(w[0]) == rect(12, 37, 508, 851))
        let (_, _, discovered) = threeWindows(exposed: false)
        #expect(plans <= discovered, "hint \(plans) vs discovered \(discovered)")
        #expect(plans <= 1, "plans: \(plans)")
    }

    @Test func unsatisfiableMinimumsConvergeWithBoundedPlans() {
        let h = Harness(); h.start()
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 900, height: 0)
        let before = h.c.testPlanCount()
        let a = h.open(1, quirks: q), b = h.open(2, quirks: q)
        let plans = h.c.testPlanCount() - before
        #expect(plans <= 6, "plans: \(plans)")
        #expect(h.frame(a)?.width == 900 && h.frame(b)?.width == 900)
        #expect(h.frame(a)?.origin == CGPoint(x: 12, y: 37))
        #expect(h.frame(b)?.origin == CGPoint(x: 724, y: 37))
        #expect(h.c.testUncooperative().isEmpty)
        let settled = h.c.testPlanCount()
        h.settle()
        #expect(h.c.testPlanCount() == settled)
    }

    @Test func closingAWindowSatisfiesAPendingMinimum() {
        let h = Harness(); h.start()
        var q = FakeWindowQuirks(); q.minSize = CGSize(width: 600, height: 0)
        let a = h.open(1, quirks: q), b = h.open(2, quirks: q), c = h.open(3, quirks: q)
        #expect(h.tiled(h.s1) == 3)
        h.desk.closeWindow(c)
        h.settle(); h.reconcile()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == rect(12, 37, 704, 851))
        #expect(h.frame(b) == rect(724, 37, 704, 851))
    }
}
