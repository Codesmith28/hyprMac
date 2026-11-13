import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

// v0.3.0 options: title rules, smart_gaps, per-display gaps, focus_follows_mouse, rules.desktop.

private func lua(_ body: String) -> String { "config = { \(body) }\n" }

@Suite struct V030ConfigTests {
    func load(_ source: String) -> Config? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-v030-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("init.lua")
        try? source.write(to: url, atomically: true, encoding: .utf8)
        if case .loaded(let c) = ConfigStore(path: url).load() { return c }
        return nil
    }

    @Test func everythingIsOffByDefault() throws {
        let c = try #require(load(lua("")))
        #expect(!c.smartGaps && !c.focusFollowsMouse && c.displays.isEmpty)
        #expect(c.rules.floatTitle.isEmpty && c.rules.ignoreTitle.isEmpty && c.rules.desktop.isEmpty)
        #expect(!Config.defaults.smartGaps && !Config.defaults.focusFollowsMouse)
    }

    @Test func parsesAllOptions() throws {
        let c = try #require(load(lua("""
            smart_gaps = true, focus_follows_mouse = true,
            displays = { ["Studio Display"] = { inner = 4, outer = 8 }, ["LG"] = { outer = 0 } },
            rules = { float_title = { "^About" }, ignore_title = { "Zoom" }, desktop = { ["com.a.b"] = 3 } }
            """)))
        #expect(c.smartGaps && c.focusFollowsMouse)
        #expect(c.displays["Studio Display"] == DisplayGapOverride(inner: 4, outer: 8))
        #expect(c.displays["LG"] == DisplayGapOverride(inner: nil, outer: 0))
        #expect(c.rules.floatTitle == ["^About"] && c.rules.ignoreTitle == ["Zoom"] && c.rules.desktop == ["com.a.b": 3])
    }

    @Test func invalidRegexKeepsThePreviousConfig() {
        #expect(load(lua("rules = { float_title = { '(' } }")) == nil)
    }
}

@Suite struct TitleRuleTests {
    @Test func matcherIsCaseInsensitiveAndSearches() {
        let m = TitleMatcher(["^picture.in.picture$", "settings"])
        #expect(m.matches("Picture in Picture") && m.matches("My Settings Window") && !m.matches("Doc"))
        #expect(!TitleMatcher().matches("anything") && TitleMatcher().isEmpty)
    }

    @Test func longTitlesAreTruncated() {
        let m = TitleMatcher(["needle$"])
        #expect(!m.matches(String(repeating: "x", count: 600) + "needle"))
        #expect(m.matches(String(repeating: "x", count: 100) + "needle"))
    }

    @Test func policyFloatsOnTitleOnly() {
        var c = Config.defaults
        c.rules = AppRules(floatTitle: ["^Preferences"])
        let big = CGSize(width: 900, height: 700)
        #expect(FloatPolicy.shouldFloat(firstSeenSize: big, config: c, title: "preferences – App"))
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: big, config: c, title: "Document"))
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: big, config: c, title: nil))
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: big, config: c, title: ""))
        #expect(!FloatPolicy.shouldFloat(firstSeenSize: big, config: c, override: .tiled, title: "Preferences"))
        #expect(FloatPolicy.shouldFloat(firstSeenSize: CGSize(width: 100, height: 100), config: c, title: "Doc")) // small rule intact
    }

    @Test func floatTitleFloatsAtFirstSight() {
        let h = Harness(config: lua("rules = { float_title = { '^About' } }")); h.start()
        let about = h.desk.addWindow(pid: 100, id: 1, frame: rect(300, 300, 600, 500), title: "About This App")
        h.desk.focus(about); h.settle()
        let doc = h.desk.addWindow(pid: 100, id: 2, frame: rect(100, 100, 600, 500), title: "Document")
        h.desk.focus(doc); h.settle()
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(about) == rect(300, 300, 600, 500))
        #expect(h.frame(doc) == root)
    }

    @Test func floatTitleDecisionIsStickyAndOverridable() {
        let h = Harness(config: lua("rules = { float_title = { '^About' } }")); h.start()
        let about = h.desk.addWindow(pid: 100, id: 1, frame: rect(300, 300, 600, 500), title: "About")
        h.desk.focus(about); h.settle()
        #expect(h.tiled(h.s1) == 0)
        h.c.queue.sync { h.c.toggleFocusedFloatNow() }
        h.settle()
        #expect(h.tiled(h.s1) == 1) // ⌥⇧F tiles it
    }

    @Test func ignoreTitleNeverManagesTheWindow() {
        let h = Harness(config: lua("rules = { ignore_title = { 'zoom meeting' } }")); h.start()
        let zoom = h.desk.addWindow(pid: 100, id: 1, frame: rect(300, 300, 600, 500), title: "Zoom Meeting")
        h.desk.focus(zoom); h.settle()
        let doc = h.desk.addWindow(pid: 100, id: 2, frame: rect(100, 100, 600, 500), title: "Doc")
        h.desk.focus(doc); h.settle()
        #expect(h.id(zoom) == nil)
        #expect(h.frame(zoom) == rect(300, 300, 600, 500))
        #expect(h.frame(doc) == root)
        // Never thrown either.
        h.desk.focus(zoom); h.desk.clock.advance(by: 2)
        h.c.throwFocusedWindow(toSpace: 2); h.settle()
        #expect(h.desk.space(of: zoom) == h.s1)
    }
}

@Suite struct GapOptionTests {
    @Test func smartGapsFillsTheScreenWithOneWindowOnly() {
        let h = Harness(config: lua("smart_gaps = true")); h.start()
        let a = h.open(1)
        #expect(h.frame(a) == mainVisible)
        let b = h.open(2)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
        h.desk.closeWindow(b); h.settle()
        #expect(h.frame(a) == mainVisible)
    }

    @Test func gapsUnchangedWithoutSmartGaps() {
        let h = Harness(); h.start()
        #expect(h.frame(h.open(1)) == root)
    }

    @Test func smartGapsFollowsConfigReload() {
        let h = Harness(); h.start()
        let a = h.open(1)
        #expect(h.frame(a) == root)
        h.reload(lua("smart_gaps = true"))
        #expect(h.frame(a) == mainVisible)
        h.reload(lua(""))
        #expect(h.frame(a) == root)
    }

    @Test func perDisplayGapsApplyByLocalizedName() {
        let h = Harness(config: lua("displays = { ['Studio Display'] = { inner = 0, outer = 0 }, ['Nope'] = { outer = 99 } }"))
        h.desk.addDisplay(2, frame: rect(1440, 0, 1600, 900), isMain: false, userSpaces: 1, name: "Studio Display")
        h.start()
        let onMain = h.open(1, frame: rect(100, 100, 500, 400))
        let onStudio = h.open(2, frame: rect(1500, 100, 500, 400))
        #expect(h.frame(onMain) == root)                              // no override: global gaps
        #expect(h.frame(onStudio) == rect(1440, 25, 1600, 875))       // overridden to zero
    }

    @Test func perDisplayGapSideFallsBackToGlobal() {
        let h = Harness(config: lua("displays = { ['Studio Display'] = { outer = 0 } }"))
        h.desk.addDisplay(2, frame: rect(1440, 0, 1600, 900), isMain: false, userSpaces: 1, name: "Studio Display")
        h.start()
        let a = h.open(1, frame: rect(1500, 100, 500, 400))
        let b = h.open(2, frame: rect(1500, 100, 500, 400))
        // outer 0, inner stays the global 8.
        #expect(h.frame(a) == rect(1440, 25, 796, 875) && h.frame(b) == rect(2244, 25, 796, 875))
    }
}

@Suite struct HoverGateTests {
    @Test func focusesOnlyAfterTheDebounce() {
        var g = HoverFocusGate()
        let w = Ref(pid: 1, windowID: 1)
        let r1 = g.noteHover(w, now: 10)
        #expect(r1)
        let r2 = g.due(now: 10.05, focused: nil)
        #expect(r2 == nil)
        #expect(g.candidate == w)
        let r3 = g.due(now: 10.12, focused: nil)
        #expect(r3 == w)
        let r0 = g.due(now: 10.5, focused: nil) // consumed
        #expect(r0 == nil)
    }

    @Test func movingToAnotherWindowRestartsTheDebounce() {
        var g = HoverFocusGate()
        let a = Ref(pid: 1, windowID: 1), b = Ref(pid: 1, windowID: 2)
        g.noteHover(a, now: 0)
        g.noteHover(b, now: 0.1)
        let r4 = g.due(now: 0.15, focused: nil)
        #expect(r4 == nil)
        let r5 = g.due(now: 0.23, focused: nil)
        #expect(r5 == b)
    }

    @Test func staysOnTheSameWindowKeepsTheOriginalStart() {
        var g = HoverFocusGate()
        let a = Ref(pid: 1, windowID: 1)
        let r6 = g.noteHover(a, now: 0)
        #expect(r6)
        let r7 = g.noteHover(a, now: 0.1)
        #expect(!r7)
        let r8 = g.due(now: 0.12, focused: nil)
        #expect(r8 == a)
    }

    @Test func neverRefocusesTheFocusedWindow() {
        var g = HoverFocusGate()
        let a = Ref(pid: 1, windowID: 1)
        g.noteHover(a, now: 0)
        let r9 = g.due(now: 1, focused: a)
        #expect(r9 == nil)
    }

    @Test func warpSuppressesMovesAndDropsTheCandidate() {
        var g = HoverFocusGate()
        let a = Ref(pid: 1, windowID: 1), b = Ref(pid: 1, windowID: 2)
        g.noteHover(a, now: 0)
        g.noteWarp(now: 0.05)
        let r10 = g.due(now: 0.3, focused: nil)
        #expect(r10 == nil)
        let s1 = g.noteHover(b, now: 0.3) // inside the 0.4 s window: ignored
        #expect(!s1)
        let r11 = g.due(now: 0.6, focused: nil)
        #expect(r11 == nil)
        let s2 = g.noteHover(b, now: 0.46) // after it: counts again
        #expect(s2)
        let r12 = g.due(now: 0.6, focused: nil)
        #expect(r12 == b)
    }

    @Test func leavingAllWindowsCancels() {
        var g = HoverFocusGate()
        g.noteHover(Ref(pid: 1, windowID: 1), now: 0)
        let r13 = g.noteHover(nil, now: 0.05)
        #expect(!r13)
        let r14 = g.due(now: 1, focused: nil)
        #expect(r14 == nil)
    }
}

@Suite struct HoverFocusTests {
    /// Space 1: B on the left (leftHalf), A on the right (rightHalf, focused).
    func setup(config: String = lua("focus_follows_mouse = true")) -> (Harness, FakeMouseMoveMonitor, Ref, Ref) {
        let mon = FakeMouseMoveMonitor()
        let h = Harness(config: config, mouseMonitor: mon); h.start()
        let b = h.open(2)
        let a = h.open(1)
        h.desk.focus(a); h.settle()
        return (h, mon, a, b)
    }
    func focused(_ h: Harness) -> Ref? { (try? h.desk.ax.focusedWindow(pid: 100)) ?? nil }

    @Test func monitorOnlyRunsWhenEnabled() {
        let (h, mon, _, _) = setup()
        #expect(mon.running)
        h.reload(lua("focus_follows_mouse = false"))
        #expect(!mon.running)
        let off = FakeMouseMoveMonitor()
        let h2 = Harness(mouseMonitor: off); h2.start()
        #expect(!off.running && off.startCount == 0)
    }

    @Test func hoveringAnotherWindowFocusesItAfterTheDebounce() {
        let (h, _, a, b) = setup()
        h.c.testMouseMoved(CGPoint(x: 300, y: 400)) // over B
        h.c.testHoverCheck()
        #expect(focused(h) == a) // too early
        h.desk.clock.advance(by: 0.13)
        h.c.testHoverCheck()
        #expect(focused(h) == b)
        #expect(!h.desk.posted.contains { if case .warpCursor = $0 { return true }; return false })
    }

    @Test func hoveringTheFocusedWindowDoesNothing() {
        let (h, _, a, _) = setup()
        h.desk.clearAXCalls()
        h.c.testMouseMoved(CGPoint(x: 1000, y: 400)) // over A, already focused
        h.desk.clock.advance(by: 0.2)
        h.c.testHoverCheck()
        #expect(focused(h) == a)
        #expect(!h.desk.axCalls.contains { if case .raise = $0 { return true }; return false })
    }

    @Test func cursorWarpSuppressesHoverFocus() {
        let (h, _, a, b) = setup()
        h.c.focus(direction: .left) // focuses B and warps the cursor onto it
        h.settle()
        #expect(focused(h) == b)
        h.desk.focus(a); h.settle()
        h.c.testMouseMoved(CGPoint(x: 300, y: 400)) // the warp's aftermath: ignored
        h.desk.clock.advance(by: 0.2)
        h.c.testHoverCheck()
        #expect(focused(h) == a)
        h.desk.clock.advance(by: 0.5) // suppression over: a real move works again
        h.c.testMouseMoved(CGPoint(x: 310, y: 410))
        h.desk.clock.advance(by: 0.13)
        h.c.testHoverCheck()
        #expect(focused(h) == b)
    }

    @Test func menuBarAndEmptyDesktopFocusNothing() {
        let (h, _, a, _) = setup()
        h.c.testMouseMoved(CGPoint(x: 5, y: 5)) // above the usable area, over no window
        h.desk.clock.advance(by: 0.2)
        h.c.testHoverCheck()
        #expect(focused(h) == a)
    }
}

@Suite struct PinDesktopTests {
    let rule = lua("rules = { desktop = { ['com.example.editor'] = 2 } }")

    @Test func newWindowIsThrownToItsDesktopOnce() {
        let h = Harness(config: rule); h.start()
        h.desk.clock.advance(by: 2)
        let a = h.open(1)
        #expect(h.desk.space(of: a) == h.s2)
        #expect(h.tiled(h.s2) == 1)
        #expect(h.recorder.notices == [.windowThrown(app: "com.example.editor", fromSpace: nil, toSpace: 2)])
        // Bringing it back by hand is never undone.
        h.desk.clock.advance(by: 2)
        h.c.throwFocusedWindow(toSpace: 1); h.settle()
        #expect(h.desk.space(of: a) == h.s1)
        h.reconcile()
        #expect(h.desk.space(of: a) == h.s1)
    }

    @Test func windowsPresentAtStartupAreNeverMoved() {
        let h = Harness(config: rule)
        let old = h.desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 600, 500))
        let otherSpace = h.desk.addWindow(pid: 100, id: 2, frame: rect(100, 100, 600, 500), space: h.s3)
        h.desk.clock.advance(by: 2)
        h.start()
        #expect(h.desk.space(of: old) == h.s1 && h.desk.space(of: otherSpace) == h.s3)
        // Visiting the other Space later doesn't make its window "new".
        h.desk.setActiveSpace(h.s3, display: 1); h.settle()
        h.reconcile()
        #expect(h.desk.space(of: otherSpace) == h.s3)
    }

    @Test func failureIsLoggedOnceAndNeverRetried() {
        let h = Harness(config: rule); h.start()
        h.desk.nativeSwitchEnabled = false // the throw times out
        h.desk.clock.advance(by: 2)
        let a = h.open(1)
        #expect(h.desk.space(of: a) == h.s1)
        #expect(h.recorder.notices.isEmpty) // silent
        let keyDowns = { h.desk.posted.filter { if case .keyDown = $0 { return true }; return false }.count }
        let first = keyDowns()
        #expect(first == 1)
        h.reconcile(); h.reconcile(); h.settle()
        #expect(keyDowns() == first)
    }

    @Test func skipsFloatingFullscreenAlreadyThereAndOtherApps() {
        // floating by rule
        let h = Harness(config: lua("rules = { float = { 'com.example.editor' }, desktop = { ['com.example.editor'] = 2 } }"))
        h.start(); h.desk.clock.advance(by: 2)
        let f = h.open(1)
        #expect(h.desk.space(of: f) == h.s1)
        // already on Desktop N
        let h2 = Harness(config: lua("rules = { desktop = { ['com.example.editor'] = 1 } }"))
        h2.start(); h2.desk.clock.advance(by: 2)
        let a = h2.open(1)
        #expect(h2.desk.space(of: a) == h2.s1 && h2.desk.posted.isEmpty)
        // an app that is not listed
        let h3 = Harness(config: rule); h3.desk.addApp(pid: 200, bundleID: "com.example.other")
        h3.start(); h3.desk.clock.advance(by: 2)
        let o = h3.open(1, pid: 200)
        #expect(h3.desk.space(of: o) == h3.s1)
        // ignored apps are never discovered
        let h4 = Harness(config: lua("rules = { ignore = { 'com.example.editor' }, desktop = { ['com.example.editor'] = 2 } }"))
        h4.start(); h4.desk.clock.advance(by: 2)
        let i = h4.open(1)
        #expect(h4.desk.space(of: i) == h4.s1)
        // a fullscreen window
        let h5 = Harness(config: rule); h5.start(); h5.desk.clock.advance(by: 2)
        let fs = h5.desk.addWindow(pid: 100, id: 1, frame: rect(100, 100, 600, 500))
        h5.desk.setFullscreen(fs, true); h5.settle()
        #expect(h5.desk.posted.isEmpty)
    }

    @Test func noSuchDesktopIsGivenUpQuietly() {
        let h = Harness(spaces: 1, config: rule); h.start(); h.desk.clock.advance(by: 2)
        let a = h.open(1)
        #expect(h.desk.space(of: a) == h.s1 && h.desk.posted.isEmpty && h.recorder.notices.isEmpty)
    }

    @Test func offByDefault() {
        let h = Harness(); h.start(); h.desk.clock.advance(by: 2)
        let a = h.open(1)
        #expect(h.desk.space(of: a) == h.s1 && h.desk.posted.isEmpty)
    }
}
