import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

@Suite struct FloatPolicyTests {
    let cfg = Config.defaults // 400 x 300

    @Test func defaultsAre400x300() {
        #expect(cfg.floatMinWidth == 400)
        #expect(cfg.floatMinHeight == 300)
    }

    @Test func smallOnEitherAxisFloats() {
        #expect(FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 300, height: 200), config: cfg))
        #expect(FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 399, height: 900), config: cfg))
        #expect(FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 900, height: 299), config: cfg))
    }

    @Test func exactlyAtThresholdTiles() {
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 400, height: 300), config: cfg))
    }

    @Test func zeroDisablesAnAxis() {
        var c = cfg
        c.floatMinWidth = 0
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 10, height: 300), config: c))
        #expect(FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 10, height: 299), config: c))
        c.floatMinHeight = 0
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 1, height: 1), config: c))
    }

    @Test func overrideWins() {
        let small = CGSize(width: 100, height: 100), big = CGSize(width: 900, height: 700)
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: small, config: cfg, override: .tiled))
        #expect(FloatPolicy.shouldFloat(firstSeenSize: big, config: cfg, override: .floating))
    }
}

/// Kit integration with the real engine: small windows float and keep their own frame.
@Suite struct FloatSmallTests {
    let small = rect(500, 500, 300, 200)

    @Test func smallWindowFloatsAndOthersTileAsTwo() {
        let h = Harness(); h.start()
        let a = h.open(1), f = h.open(2, frame: small), b = h.open(3)
        #expect(h.frame(f) == small)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        #expect(h.tiled(h.s1) == 2)
    }

    @Test func windowExactlyAtThresholdTiles() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2, frame: rect(500, 500, 400, 300))
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        let c = h.open(3, frame: rect(500, 500, 399, 300)) // one point short on width
        #expect(h.frame(c) == rect(500, 500, 399, 300))
        #expect(h.tiled(h.s1) == 2)
    }

    @Test func zeroDisablesFloating() {
        let h = Harness(config: "config = { float = { min_width = 0, min_height = 0 } }\n"); h.start()
        let a = h.open(1), b = h.open(2, frame: small)
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func customThresholdFromConfig() {
        let h = Harness(config: "config = { float = { min_width = 0, min_height = 250 } }\n"); h.start()
        let a = h.open(1), f = h.open(2, frame: small) // 200 < 250
        #expect(h.frame(f) == small)
        #expect(h.frame(a) == root)
        let g = h.open(3, frame: rect(500, 500, 100, 250)) // width axis off, height at threshold
        #expect(h.tiled(h.s1) == 2)
        _ = g
    }

    @Test func decisionIsStickyAfterLaterResize() {
        let h = Harness(); h.start()
        let a = h.open(1), f = h.open(2, frame: small)
        let big = rect(100, 100, 800, 600)
        h.desk.setFrame(f, big); h.reconcile()
        #expect(h.frame(f) == big)            // still floating: not pulled into the tree
        #expect(h.frame(a) == root)
        #expect(h.tiled(h.s1) == 1)
        // And a tiled window that is later shrunk stays tiled.
        let b = h.open(3)
        #expect(h.tiled(h.s1) == 2)
        h.desk.setFrame(b, rect(300, 300, 100, 100)); h.reconcile()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func overrideFlipsTheDecision() {
        let h = Harness(); h.start()
        let a = h.open(1), f = h.open(2, frame: small)
        #expect(h.tiled(h.s1) == 1)
        let fid = h.id(f)!
        h.c.queue.sync { h.c.floatOverride[fid] = .tiled }
        h.reconcile()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(f) == rightHalf)
        h.c.queue.sync { h.c.floatOverride[fid] = .floating }
        h.reconcile()
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(a) == root)
    }

    @Test func reloadAppliesOnlyToWindowsSeenAfterwards() {
        let h = Harness(); h.start()
        let a = h.open(1), f = h.open(2, frame: small)
        #expect(h.frame(f) == small)
        h.reload("config = { float = { min_width = 0, min_height = 0 } }\n")
        h.reconcile()
        #expect(h.frame(f) == small)          // already decided: still floating
        #expect(h.tiled(h.s1) == 1)
        let g = h.open(3, frame: small)       // first seen under the new thresholds: tiles
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(g) == rightHalf)
    }
}
