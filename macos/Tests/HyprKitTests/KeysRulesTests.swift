import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

private let ctrlAltKeys = """
config = { keys = { throw = "ctrl+alt", toggle_float = "ctrl+alt+t", switch = "ctrl" } }
"""

@Suite struct ConfigKeysTests {
    func store(_ lua: String) -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-keys-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("init.lua")
        try? lua.write(to: url, atomically: true, encoding: .utf8)
        return (ConfigStore(path: url), dir)
    }

    @Test func extrasJSONParses() throws {
        let json = #"{"keys":{"throw":"ctrl+alt","toggle_float":"ctrl+alt+t","switch":"ctrl"},"rules":{"ignore":["a.b"],"float":["c.d","e.f"]}}"#
        let e = try #require(Config.parseExtras(json: json))
        #expect(e.keys.throwModifiers == [.control, .option] && e.keys.toggleFloat.key == "t" && e.keys.switchModifiers == .control)
        #expect(e.rules == AppRules(ignore: ["a.b"], float: ["c.d", "e.f"]))
        #expect(Config.parseExtras(json: "{}") == nil)
        #expect(Config.parseExtras(json: "nope") == nil)
    }

    @Test func defaultsWhenAbsent() {
        let (s, dir) = store("config = { gaps = { inner = 3 } }\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .loaded(let c) = s.load() else { Issue.record("not loaded"); return }
        #expect(c.keys == .defaults && c.rules == AppRules())
        #expect(Config.defaults.keys == .defaults)
    }

    @Test func loadsKeysAndRules() {
        let (s, dir) = store(ctrlAltKeys.dropLast(2) + ", rules = { ignore = { 'x.y' }, float = { 'z.w' } } }\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .loaded(let c) = s.load() else { Issue.record("not loaded"); return }
        #expect(c.keys.throwModifiers == [.control, .option] && c.keys.switchModifiers == .control)
        #expect(c.rules == AppRules(ignore: ["x.y"], float: ["z.w"]))
    }

    @Test func invalidKeysKeepThePreviousConfig() throws {
        let (s, dir) = store(ctrlAltKeys)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .loaded(let good) = s.load() else { Issue.record("not loaded"); return }
        try "config = { keys = { throw = 'hyper' } }\n".write(to: s.path, atomically: true, encoding: .utf8)
        guard case .failedKeptPrevious(let message, let kept) = s.load() else { Issue.record("accepted"); return }
        #expect(message.hasSuffix("init.lua: keys.throw: unknown modifier 'hyper'"))
        #expect(kept == good && s.current == good)
    }
}

@Suite struct KeysRulesCoordinatorTests {
    @Test func defaultsRegisterTheOriginalShortcuts() {
        let h = Harness(); h.start()
        #expect(h.hotkeys.bindings == .defaults && h.hotkeys.startCount == 1)
        #expect(h.spaceKeys.modifiers == .maskAlternate && h.spaceKeys.startCount == 1)
    }

    @Test func configuredKeysAreRegisteredFromTheSpec() {
        let h = Harness(config: ctrlAltKeys); h.start()
        let b = h.hotkeys.bindings
        #expect(b?.throwModifiers == [.control, .option] && b?.toggleFloat.display == "⌃⌥T")
        #expect(h.hotkeys.registrations.count == 27)
        #expect(h.spaceKeys.modifiers == .maskControl)
        #expect(h.recorder.notices.isEmpty)
    }

    @Test func aBrokenFirstConfigStillRegistersTheDefaults() {
        let h = Harness(config: "config = { keys = { throw = 'hyper' } }\n"); h.start()
        #expect(h.hotkeys.bindings == .defaults)
        #expect(h.recorder.notices.contains { if case .configError = $0 { return true }; return false })
    }

    @Test func reloadReRegistersAndReappliesTheTapFilter() {
        let h = Harness(); h.start()
        h.reload(ctrlAltKeys)
        #expect(h.hotkeys.startCount == 2 && h.hotkeys.bindings?.throwModifiers == [.control, .option])
        #expect(h.spaceKeys.startCount == 2 && h.spaceKeys.modifiers == .maskControl)
        // Unchanged keys still re-register on a reload.
        h.reload(ctrlAltKeys)
        #expect(h.hotkeys.startCount == 3)
        // The new ⌃ switch modifiers drive the missing-Desktop notice.
        h.spaceKeys.key(25, flags: .maskAlternate)   // ⌥9: no longer a switch
        h.spaceKeys.key(25, flags: .maskControl)     // ⌃9: 3 desktops only
        h.c.queue.sync {}
        h.settle()
        #expect(h.recorder.count(.missingSpace(requested: 9, count: 3)) == 1)
    }

    @Test func aBadReloadKeepsThePreviousRegistrations() {
        let h = Harness(config: ctrlAltKeys); h.start()
        let before = h.hotkeys.bindings
        h.reload("config = { keys = { toggle_float = 'alt+shift' } }\n")
        #expect(h.hotkeys.bindings == before && h.hotkeys.startCount == 1)
        #expect(h.recorder.notices.contains { if case .configError = $0 { return true }; return false })
    }

    @Test func registrationFailureShowsANotice() {
        let h = Harness(); h.hotkeys.failingDigits = [3]; h.hotkeys.toggleFloatFailed = true
        h.start()
        #expect(h.recorder.notices.contains(.hotkeysUnavailable("⌥⇧3, ⌥⇧F")))
    }

    // MARK: switch shortcut warning

    @Test func warnsWhenSwitchDoesNotMatchTheNativeShortcut() {
        let h = Harness(config: "config = { keys = { throw = 'ctrl+alt', switch = 'alt' } }\n",
                        nativeShortcuts: FakeNativeSwitchShortcuts([1: .maskControl, 2: .maskControl]))
        h.start()
        #expect(h.recorder.notices.contains(.switchShortcutMismatch(configured: "⌥", native: ["⌃"])))
    }

    @Test func noWarningWhenSwitchMatchesAnEnabledShortcut() {
        let h = Harness(nativeShortcuts: FakeNativeSwitchShortcuts([1: .maskControl, 8: .maskAlternate]))
        h.start()
        #expect(h.recorder.notices.isEmpty)
    }

    @Test func warnsWhenNoDesktopShortcutIsEnabled() {
        let h = Harness(nativeShortcuts: FakeNativeSwitchShortcuts([:]))
        h.start()
        #expect(h.recorder.notices.contains(.switchShortcutMismatch(configured: "⌥", native: [])))
    }

    // MARK: rules

    private func addApp(_ h: Harness, pid: pid_t, bundle: String) { h.desk.addApp(pid: pid, bundleID: bundle) }

    @Test func ignoredAppsAreNeverTiledOrMoved() {
        let h = Harness(config: "config = { rules = { ignore = { 'com.example.ignored' } } }\n"); h.start()
        addApp(h, pid: 200, bundle: "com.example.ignored")
        let original = rect(300, 300, 500, 400)
        let a = h.open(1), term = h.open(2, pid: 200, frame: original), b = h.open(3)
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(term) == original)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
        #expect(h.id(term) == nil)
        h.reconcile()
        #expect(h.frame(term) == original)
    }

    @Test func ignoredAppsAreNotThrownOrToggled() {
        let h = Harness(config: "config = { rules = { ignore = { 'com.example.ignored' } } }\n"); h.start()
        addApp(h, pid: 200, bundle: "com.example.ignored")
        let original = rect(300, 300, 500, 400)
        let term = h.open(1, pid: 200, frame: original)
        h.desk.focus(term)
        h.hotkeys.press(2); h.settle()
        h.hotkeys.pressToggleFloat(); h.settle()
        #expect(h.desk.posted.isEmpty)
        #expect(h.frame(term) == original)
        #expect(h.c.testFloatOverride().isEmpty)
    }

    @Test func reloadingIgnoreRulesAppliesToRunningApps() {
        let h = Harness(); h.start()
        addApp(h, pid: 200, bundle: "com.example.ignored")
        let a = h.open(1), t = h.open(2, pid: 200)
        #expect(h.tiled(h.s1) == 2)
        h.reload("config = { rules = { ignore = { 'com.example.ignored' } } }\n")
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(a) == root)
        _ = t
    }

    @Test func floatRuleFloatsAnAppAndOthersTileAsTwo() {
        let h = Harness(config: "config = { rules = { float = { 'com.example.floaty' } } }\n"); h.start()
        addApp(h, pid: 300, bundle: "com.example.floaty")
        let original = rect(300, 300, 500, 400)
        let a = h.open(1), f = h.open(2, pid: 300, frame: original), b = h.open(3)
        #expect(h.tiled(h.s1) == 2)
        #expect(h.frame(f) == original)
        #expect(h.frame(a) == leftHalf && h.frame(b) == rightHalf)
    }

    @Test func floatRuleWindowsCanStillBeTiledWithTheToggle() {
        let h = Harness(config: "config = { rules = { float = { 'com.example.floaty' } } }\n"); h.start()
        addApp(h, pid: 300, bundle: "com.example.floaty")
        _ = h.open(1)
        let f = h.open(2, pid: 300, frame: rect(300, 300, 500, 400))
        #expect(h.tiled(h.s1) == 1)
        h.desk.focus(f)
        h.hotkeys.pressToggleFloat(); h.settle()
        #expect(h.tiled(h.s1) == 2)
        #expect(h.c.testFloatOverride()[h.id(f)!] == false)
        h.hotkeys.pressToggleFloat(); h.settle()
        #expect(h.tiled(h.s1) == 1)
    }

    @Test func builtInFloatListStillApplies() {
        let h = Harness(config: "config = { rules = { float = { 'com.example.floaty' } } }\n"); h.start()
        addApp(h, pid: 400, bundle: "com.apple.calculator")
        _ = h.open(1)
        _ = h.open(2, pid: 400, frame: rect(300, 300, 500, 400))
        #expect(h.tiled(h.s1) == 1)
    }
}
