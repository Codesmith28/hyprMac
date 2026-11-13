import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// resize / equalize / rotate / zoom / display move / pause / macOS-shortcut conflicts.
@Suite struct ActionsTests {
    private func started(_ config: String? = nil, native: NativeSwitchShortcuts? = nil) -> Harness {
        let h = Harness(config: config, nativeShortcuts: native); h.start()
        return h
    }

    @Test func resizeRightGrowsTheFocusedTileByTheStep() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(a); h.settle()
        h.hotkeys.pressAction(.resizeRight); h.settle()
        #expect(abs(h.frame(a)!.width - 774.4) < 0.01)
        #expect(abs(h.frame(b)!.minX - 794.4) < 0.01)
        h.hotkeys.pressAction(.resizeLeft); h.settle()
        #expect(h.frame(a) == leftHalf)
    }

    @Test func resizeStepOptionIsUsed() {
        let h = started("config = { resize_step = 10 }\n")
        let a = h.open(1); _ = h.open(2)
        h.desk.focus(a); h.settle()
        h.hotkeys.pressAction(.resizeRight); h.settle()
        #expect(abs(h.frame(a)!.width - 844.8) < 0.01)
    }

    @Test func equalizeResetsEverySplit() {
        let h = started()
        let a = h.open(1); _ = h.open(2); _ = h.open(3)
        h.desk.focus(a); h.settle()
        h.hotkeys.pressAction(.resizeRight); h.settle()
        #expect(h.frame(a) != leftHalf)
        h.hotkeys.pressAction(.equalize); h.settle()
        #expect(h.frame(a) == leftHalf)
    }

    @Test func rotateSplitStacksTheTwoTiles() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(b); h.settle()
        h.hotkeys.pressAction(.rotateSplit); h.settle()
        #expect(h.frame(a) == rect(12, 37, 1416, 421.5))
        #expect(h.frame(b) == rect(12, 466.5, 1416, 421.5))
    }

    @Test func zoomFillsTheWorkAreaAndRestores() {
        let h = started()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        let before = [a, b, c].map { h.frame($0)! }
        h.desk.focus(b); h.settle()
        h.hotkeys.pressAction(.toggleZoom); h.settle()
        #expect(h.frame(b) == root)
        #expect(h.frame(a) == before[0])
        h.hotkeys.pressAction(.toggleZoom); h.settle()
        #expect([a, b, c].map { h.frame($0)! } == before)
    }

    @Test func zoomEndsWhenTheWindowCloses() {
        let h = started()
        let a = h.open(1), b = h.open(2), c = h.open(3)
        h.desk.focus(b); h.settle()
        h.hotkeys.pressAction(.toggleZoom); h.settle()
        h.desk.closeWindow(b); h.settle()
        #expect(h.frame(a) != nil && h.frame(c) != nil)
        #expect(h.frame(a) == leftHalf)
        #expect(h.c.queue.sync { h.c.engine.zoomedWindow(space: h.s1) } == nil)
    }

    @Test func togglePauseActsLikeTheMenuItem() {
        let h = started()
        _ = h.open(1)
        #expect(!h.c.isPaused)
        h.hotkeys.pressAction(.togglePause); h.settle()
        #expect(h.c.isPaused)
        h.hotkeys.pressAction(.togglePause); h.settle()
        #expect(!h.c.isPaused)
    }

    @Test func movesToTheNextDisplayAndReflowsBoth() {
        let h = Harness(); 
        let ids = h.desk.addDisplay(2, frame: rect(-1920, 0, 1920, 1080), visibleFrame: rect(-1920, 25, 1920, 1055))
        h.start()
        let a = h.open(1), b = h.open(2)
        _ = h.open(3, frame: rect(-1500, 100, 400, 300), space: ids[0])
        h.desk.focus(a); h.settle()
        #expect(h.tiled(h.s1) == 2 && h.tiled(ids[0]) == 1)
        h.hotkeys.pressAction(.moveDisplayNext); h.settle()
        // macOS reassigns a window dragged onto another display; the fake needs telling.
        h.desk.moveWindow(a, toSpace: ids[0]); h.settle()
        h.reconcile()
        #expect(h.tiled(h.s1) == 1 && h.tiled(ids[0]) == 2)
        #expect(h.frame(b) == root)
        #expect(rect(-1920, 25, 1920, 1055).contains(h.frame(a)!))
    }

    @Test func actionsAreUnboundByDefaultExceptFlipSplitAndBoundFromConfig() {
        var h = started()
        let defaults = Set(h.hotkeys.registrations.map(\.id))
        #expect(KeyAction.allCases.filter { $0 != .rotateSplit }.allSatisfy { !defaults.contains(HotkeyCenter.hotkeyID(for: $0)) })
        // Flip split ships on ⌥⇧R (keyCode 15).
        #expect(h.hotkeys.registrations.contains { $0.id == HotkeyCenter.hotkeyID(for: .rotateSplit) && $0.keyCode == 15 })
        h = started("config = { keys = { resize_left = 'alt+shift+y', toggle_pause = 'alt+shift+p' } }\n")
        let regs = h.hotkeys.registrations
        #expect(regs.contains { $0.id == HotkeyCenter.hotkeyID(for: .resizeLeft) && $0.keyCode == 16 })
        #expect(regs.contains { $0.id == HotkeyCenter.hotkeyID(for: .togglePause) && $0.keyCode == 35 })
        #expect(!regs.contains { $0.id == HotkeyCenter.hotkeyID(for: .equalize) })
    }

    @Test func aChordMacOSOwnsIsNotRegisteredAndIsReported() {
        let native = FakeNativeSwitchShortcuts(chords: [
            SystemChord(modifiers: [.option, .shift], keyCode: 3, name: "Spotlight"),
        ])
        let h = started(native: native)
        #expect(!h.hotkeys.registrations.contains { $0.id == HotkeyCenter.toggleFloatID })
        #expect(h.hotkeys.registrations.contains { $0.id == HotkeyCenter.centerWindowID })
        #expect(h.recorder.notices.contains(.hotkeysUnavailable("⌥⇧F conflicts with a macOS shortcut (Spotlight)")))
    }
}
