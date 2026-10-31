import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

/// A delegate that synchronously reads `isPaused` inside every callback (what the menu bar
/// shell does). Delivering a callback from inside `queue` / `queue.sync` would re-enter the
/// coordinator queue and trap.
final class ReentrantDelegate: TilingControllerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seen: [(TilingNotice?, Bool)] = []
    func tiling(_ controller: TilingController, didPost notice: TilingNotice) {
        let p = controller.isPaused
        lock.lock(); seen.append((notice, p)); lock.unlock()
    }
    func tilingStateChanged(_ controller: TilingController) {
        let p = controller.isPaused
        lock.lock(); seen.append((nil, p)); lock.unlock()
    }
    var snapshot: [(TilingNotice?, Bool)] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Suite struct SystemTests {
    @Test func delegateMayReadIsPausedInsideCallbacks() {
        let h = Harness(config: "this is not lua")
        let d = ReentrantDelegate()
        h.c.delegate = d
        h.system.isStageManagerEnabled = true
        h.system.isRectangleRunning = true
        h.start() // posts stageManagerEnabled, stateChanged, configError, conflictingApp from inside start()
        let seen = d.snapshot
        #expect(seen.contains { $0.0 == .stageManagerEnabled && $0.1 })
        #expect(seen.contains { $0.0 == nil && $0.1 })
        #expect(seen.contains { if case .configError = $0.0 { return true }; return false })
        #expect(seen.contains { $0.0 == .conflictingApp(name: "Rectangle") })
        h.desk.ax.trusted = false
        h.reconcile() // permissionLost is posted from inside reconcileNow (on the queue)
        #expect(d.snapshot.contains { $0.0 == .permissionLost })
        h.c.setPaused(true, reason: nil); h.settle()
        #expect(d.snapshot.last.map { $0.0 == nil && $0.1 } == true)
    }

    @Test func isPausedIsSafeOnTheCoordinatorQueue() {
        let h = Harness(); h.start()
        let paused = h.c.queue.sync { h.c.isPaused }
        #expect(!paused)
    }

    @Test func stageManagerPausesAndResumes() {
        let h = Harness(); h.start()
        let a = h.open(1)
        h.system.isStageManagerEnabled = true
        h.send(.activeSpaceChanged)
        #expect(h.c.isPaused)
        #expect(h.recorder.count(.stageManagerEnabled) == 1)
        let b = h.open(2, frame: rect(300, 300, 400, 300))
        #expect(h.frame(b) == rect(300, 300, 400, 300)) // not tiled while paused
        #expect(h.frame(a) == root)
        h.system.isStageManagerEnabled = false
        h.reconcile()
        #expect(!h.c.isPaused)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
        #expect(h.recorder.stateChanges >= 2)
        #expect(h.recorder.count(.stageManagerEnabled) == 1)
    }

    @Test func rectangleWarnedOnce() {
        let h = Harness()
        h.system.isRectangleRunning = true
        h.start()
        h.reconcile(); h.reconcile()
        h.send(.activeSpaceChanged)
        #expect(h.recorder.count(.conflictingApp(name: "Rectangle")) == 1)
    }

    @Test func permissionLostStopsTiling() {
        let h = Harness(); h.start()
        h.open(1)
        h.desk.ax.trusted = false
        h.reconcile()
        let b = h.open(2, frame: rect(300, 300, 400, 300))
        h.reconcile()
        #expect(h.recorder.count(.permissionLost) == 1)
        #expect(h.frame(b) == rect(300, 300, 400, 300))
    }

    @Test func userPauseAndResume() {
        let h = Harness(); h.start()
        let a = h.open(1)
        h.c.setPaused(true, reason: "test"); h.settle()
        #expect(h.c.isPaused)
        let b = h.open(2, frame: rect(300, 300, 400, 300))
        #expect(h.frame(b) == rect(300, 300, 400, 300))
        h.c.setPaused(false, reason: nil); h.settle()
        #expect(!h.c.isPaused)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
        #expect(h.recorder.stateChanges == 2)
    }

    @Test func configFileGapsUsedAtStart() {
        let h = Harness(config: gapsLua(inner: 20, outer: 30)); h.start()
        let a = h.open(1), b = h.open(2)
        #expect(h.frame(a) == rect(30, 55, 680, 815))
        #expect(h.frame(b) == rect(730, 55, 680, 815))
        #expect(h.recorder.notices.isEmpty) // initial load doesn't announce itself
    }

    @Test func configReloadChangesGaps() {
        let h = Harness(); h.start()
        let a = h.open(1), b = h.open(2)
        h.reload(gapsLua(inner: 0, outer: 0))
        #expect(h.frame(a) == rect(0, 25, 720, 875))
        #expect(h.frame(b) == rect(720, 25, 720, 875))
        #expect(h.recorder.count(.configLoaded) == 1)
    }

    @Test func badConfigKeepsPreviousGaps() {
        let h = Harness(config: gapsLua(inner: 20, outer: 30)); h.start()
        let a = h.open(1), b = h.open(2)
        h.reload("config = { gaps = { inner = 9999 } }\n")
        #expect(h.frame(a) == rect(30, 55, 680, 815))
        #expect(h.frame(b) == rect(730, 55, 680, 815))
        h.reload("config = {{{ syntax error")
        #expect(h.frame(a) == rect(30, 55, 680, 815))
        let errors = h.recorder.notices.filter { if case .configError = $0 { return true }; return false }
        #expect(errors.count == 2)
        #expect(h.recorder.count(.configLoaded) == 0)
    }

    @Test func inputSourcesStartAndStop() {
        let h = Harness()
        h.hotkeys.failingDigits = [9]
        h.start()
        let a = h.open(1)
        h.c.stop()
        h.hotkeys.press(2) // stopped: no throw
        h.settle()
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.desk.posted.isEmpty)
        // No reconcile after stop.
        let b = h.open(2, frame: rect(300, 300, 400, 300))
        #expect(h.frame(b) == rect(300, 300, 400, 300))
    }
}
