import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// ⌥⇧F: toggle the focused window between floating and tiled.
@Suite struct ToggleFloatTests {
    /// Default `Harness.open` frame (the "original" size every window has when first seen).
    let original = rect(200, 200, 400, 300)
    /// Centre of `mainVisible` for a 400×300 window.
    let centred = rect(520, 312.5, 400, 300)

    private func toggle(_ h: Harness) {
        h.hotkeys.pressToggleFloat()
        h.settle()
    }

    private func started() -> Harness {
        let h = Harness(); h.start()
        h.c.queue.sync {} // hotkeys are wired in start()'s onMain block (inline in tests)
        return h
    }

    @Test func toggleSecondOfThreeFloatsItAtOriginalSizeCentred() {
        let h = started()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        h.desk.focus(b)
        toggle(h)
        #expect(h.c.testFloatOverride()[h.id(b)!] == true)
        #expect(h.frame(b) == centred)
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(c) == rightHalf)
    }

    @Test func toggleBackReinsertsIntoTheTree() {
        let h = started()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        h.desk.focus(b)
        toggle(h)
        #expect(h.tiled(h.s1) == 2)
        h.desk.focus(b)
        toggle(h)
        #expect(h.tiled(h.s1) == 3)
        #expect(h.c.testFloatOverride()[h.id(b)!] == false)
        for w in [a, b, c] { #expect(h.frame(w) != centred) }
        // Sticky: further reconciles keep it tiled.
        h.reconcile()
        #expect(h.tiled(h.s1) == 3)
    }

    /// Real macOS (toggle-float E2E): B (top-right) floats and comes back top-right, not swapped with C.
    @Test func toggleBackRestoresTheSameSlot() {
        let h = started()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        let before = [a, b, c].map { h.frame($0)! }
        #expect(before[1].minY < before[2].minY)
        h.desk.focus(b); toggle(h)
        h.desk.focus(b); toggle(h)
        #expect([a, b, c].map { h.frame($0)! } == before)
    }

    @Test func slotSurvivesChangesWhileFloating() {
        let h = started()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        h.desk.focus(b); toggle(h)
        h.desk.closeWindow(c); h.settle() // sibling gone while B floats
        #expect(h.frame(a) == root)
        h.desk.focus(b); toggle(h)
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
    }

    @Test func floatedChoiceIsStickyAcrossReconciles() {
        let h = started()
        _ = h.open(1); let b = h.open(2)
        toggle(h) // b is focused (just opened)
        h.reconcile(); h.reconcile()
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(b) == centred)
    }

    @Test func togglingUncooperativeFloatingWindowTilesIt() {
        let h = started()
        let a = h.open(1)
        var q = FakeWindowQuirks(); q.snapsBack = true
        let b = h.open(2, quirks: q)
        #expect(h.c.testUncooperative() == [h.id(b)!])
        #expect(h.tiled(h.s1) == 1)
        h.desk.updateQuirks(b) { $0.snapsBack = false }
        h.desk.focus(b)
        toggle(h)
        #expect(h.c.testUncooperative().isEmpty)
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
    }

    @Test func overrideBeatsAutomaticFloatingAndRetileAll() {
        let h = started()
        _ = h.open(1)
        var q = FakeWindowQuirks(); q.snapsBack = true
        let b = h.open(2, quirks: q)
        h.desk.updateQuirks(b) { $0.snapsBack = false }
        h.desk.focus(b)
        toggle(h) // uncooperative → tiled (override false)
        h.c.retileAll(); h.settle()
        #expect(h.tiled(h.s1) == 2)
    }

    @Test func nonResizableEligibilityFloatIsNotOverridden() {
        let h = started()
        _ = h.open(1)
        let d = h.open(2, resizable: false)
        #expect(h.tiled(h.s1) == 1)
        h.desk.focus(d)
        toggle(h)
        #expect(h.tiled(h.s1) == 1)
        #expect(h.c.testFloatOverride().isEmpty)
    }

    @Test func noFocusedWindowIsNoOp() {
        let h = started()
        _ = h.open(1, focus: false); _ = h.open(2, focus: false)
        let plans = h.c.testPlanCount()
        toggle(h)
        #expect(h.c.testFloatOverride().isEmpty)
        #expect(h.c.testPlanCount() == plans)
        #expect(h.tiled(h.s1) == 2)
    }

    @Test func fullscreenWindowIsNoOp() {
        let h = started()
        _ = h.open(1); let b = h.open(2)
        h.desk.setFullscreen(b, true); h.settle()
        h.desk.focus(b)
        toggle(h)
        #expect(h.c.testFloatOverride().isEmpty)
    }

    @Test func overrideIsClearedOnAppTermination() {
        let h = started()
        _ = h.open(1); let b = h.open(2)
        let id = h.id(b)!
        toggle(h)
        #expect(h.c.testFloatOverride()[id] == true)
        #expect(h.c.testFirstSeenFrame(id) == original)
        h.desk.terminate(pid: 100); h.settle()
        #expect(h.c.testFloatOverride().isEmpty)
        #expect(h.c.testFirstSeenFrame(id) == nil)
    }

    @Test func overrideIsClearedWhenWindowCloses() {
        let h = started()
        _ = h.open(1); let b = h.open(2)
        toggle(h)
        h.desk.closeWindow(b); h.settle()
        #expect(h.c.testFloatOverride().isEmpty)
    }

    @Test func restoreWriteIsNotCountedAsAFight() {
        let h = started()
        _ = h.open(1); let b = h.open(2)
        let id = h.id(b)!
        toggle(h)
        #expect(h.frame(b) == centred)
        #expect(h.c.testFightCount(id) == 0)
        #expect(h.c.testUncooperative().isEmpty)
        // The write's moved/resized echoes are treated as ours.
        h.send(.window(.moved, pid: 100, window: b))
        h.send(.window(.resized, pid: 100, window: b))
        #expect(h.c.testFightCount(id) == 0)
        #expect(h.c.testUncooperative().isEmpty)
    }

    @Test func restoreIsClampedInsideTheUsableRect() {
        let h = started()
        _ = h.open(1); let b = h.open(2, frame: rect(0, 25, 3000, 2000))
        toggle(h)
        #expect(h.frame(b) == mainVisible)
    }

    @Test func toggleFloatPostsWindowStateToggledNotices() {
        let h = started()
        let a = h.open(1)
        h.desk.focus(a)
        toggle(h)
        #expect(h.recorder.notices.contains(.windowStateToggled(app: "com.example.editor", state: .floating)))

        h.desk.focus(a)
        toggle(h)
        #expect(h.recorder.notices.contains(.windowStateToggled(app: "com.example.editor", state: .tiled)))
    }

    @Test func toggleFloatUsesAppNameWhenAvailable() {
        let h = started()
        h.desk.addApp(pid: 200, bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        let w = h.open(10, pid: 200)
        h.desk.focus(w)
        toggle(h)
        #expect(h.recorder.notices.contains(.windowStateToggled(app: "Ghostty", state: .floating)))

        h.desk.focus(w)
        toggle(h)
        #expect(h.recorder.notices.contains(.windowStateToggled(app: "Ghostty", state: .tiled)))
    }
}
