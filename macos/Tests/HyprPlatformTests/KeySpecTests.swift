import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

@Suite struct KeySpecTests {
    @Test func modifierNamesAndAliases() {
        #expect(KeyModifiers(parsing: "alt+shift") == [.option, .shift])
        #expect(KeyModifiers(parsing: "OPT") == .option)
        #expect(KeyModifiers(parsing: "Option+Control") == [.option, .control])
        #expect(KeyModifiers(parsing: "command+ctrl+shift+alt") == [.command, .control, .shift, .option])
        #expect(KeyModifiers(parsing: "") == nil)
        #expect(KeyModifiers(parsing: "hyper") == nil)
        #expect(KeyModifiers(parsing: "alt+alt") == nil)
        #expect(KeyModifiers(parsing: "alt+") == nil)
    }

    @Test func carbonAndCGMappings() {
        #expect(KeyModifiers([.option, .shift]).carbon == UInt32(optionKey | shiftKey))
        #expect(KeyModifiers([.control, .option]).carbon == UInt32(controlKey | optionKey))
        #expect(KeyModifiers.command.carbon == UInt32(cmdKey))
        #expect(KeyModifiers([.option, .shift]).cgFlags == [.maskAlternate, .maskShift])
        #expect(KeyModifiers.control.cgFlags == .maskControl)
        let all: KeyModifiers = [.control, .option, .shift, .command]
        #expect(KeyModifiers(cgFlags: all.cgFlags) == all)
        #expect(KeyModifiers(cgFlags: [.maskAlternate, .maskAlphaShift]) == .option) // caps lock ignored
        #expect(all.symbols == "⌃⌥⇧⌘")
        #expect(KeyModifiers([.option, .shift]).symbols == "⌥⇧")
    }

    @Test func keySpecParsing() throws {
        let t = try #require(KeySpec(parsing: "Ctrl+Alt+T"))
        #expect(t.modifiers == [.control, .option] && t.key == "t" && t.keyCode == UInt32(kVK_ANSI_T))
        #expect(t.display == "⌃⌥T")
        #expect(KeySpec(parsing: "alt+shift+f")?.keyCode == UInt32(kVK_ANSI_F))
        #expect(KeySpec(parsing: "f") == nil)             // needs a modifier
        #expect(KeySpec(parsing: "alt+shift") == nil)     // needs a key
        #expect(KeySpec(parsing: "alt+f+g") == nil)
        #expect(KeySpec(parsing: "alt+banana") == nil)
    }

    /// The names the C++ grammar accepts (core/src/keyspec.cpp) must all have a key code.
    @Test func everyGrammarKeyNameHasAKeyCode() {
        var names = (97...122).map { String(UnicodeScalar($0)!) } + (0...9).map(String.init)
        names += (1...12).map { "f\($0)" }
        names += ["space", "tab", "return", "escape", "grave", "minus", "equal", "comma", "period", "slash", "left", "right", "up", "down"]
        #expect(names.count == 62)
        for n in names { #expect(KeySpec.keyCodes[n] != nil, "\(n)") }
        #expect(KeySpec.keyCodes.count == names.count)
        #expect(Set(KeySpec.keyCodes.values).count == names.count) // no two names share a key
    }

    @Test func spotCheckKeyCodesAgainstCarbon() {
        let pairs: [(String, Int)] = [("a", kVK_ANSI_A), ("z", kVK_ANSI_Z), ("m", kVK_ANSI_M), ("0", kVK_ANSI_0),
                                      ("9", kVK_ANSI_9), ("space", kVK_Space), ("tab", kVK_Tab),
                                      ("return", kVK_Return), ("escape", kVK_Escape), ("grave", kVK_ANSI_Grave),
                                      ("minus", kVK_ANSI_Minus), ("equal", kVK_ANSI_Equal),
                                      ("comma", kVK_ANSI_Comma), ("period", kVK_ANSI_Period),
                                      ("slash", kVK_ANSI_Slash), ("f1", kVK_F1), ("f5", kVK_F5), ("f12", kVK_F12)]
        for (name, code) in pairs { #expect(KeySpec.keyCodes[name] == UInt32(code), "\(name)") }
        for n in 1...9 { #expect(KeySpec.keyCodes[String(n)] == UInt32(DigitKeys.keyCode(forDigit: n)!)) }
    }

    @Test func defaultsEqualTheHardCodedBehaviour() {
        let d = KeyBindings.defaults
        #expect(d.throwModifiers == [.option, .shift] && d.switchModifiers == .option)
        #expect(d.toggleFloat.display == "⌥⇧F" && d.toggleFloat.keyCode == UInt32(kVK_ANSI_F))
        #expect(KeyBindings(throw: "alt+shift", toggleFloat: "alt+shift+f", switch: "alt") == d)
        #expect(KeyBindings(throw: "alt+shift", toggleFloat: "alt+shift", switch: "alt") == nil)
    }
}

@Suite struct ConfigurableHotkeyTests {
    let custom = KeyBindings(throw: "ctrl+alt", toggleFloat: "ctrl+alt+t", switch: "ctrl")!

    @Test func registrationsFollowTheSpec() {
        let regs = HotkeyCenter.registrations(for: custom)
        #expect(regs.count == 27)
        let ctrlAlt = UInt32(controlKey | optionKey)
        for n in 1...9 {
            #expect(regs[n - 1].id == UInt32(n) && regs[n - 1].modifiers == ctrlAlt)
            #expect(regs[n - 1].keyCode == UInt32(DigitKeys.keyCode(forDigit: n)!))
        }
        #expect(regs[9].id == HotkeyCenter.toggleFloatID && regs[9].keyCode == UInt32(kVK_ANSI_T) && regs[9].modifiers == ctrlAlt)
        // Defaults throw and toggle.
        let d = HotkeyCenter.registrations(for: .defaults)
        for n in 0...9 {
            #expect(d[n].modifiers == UInt32(optionKey | shiftKey))
        }
        #expect(d[9].keyCode == UInt32(kVK_ANSI_F))
        #expect(d[10].id == HotkeyCenter.centerWindowID && d[10].keyCode == 8) // 'c'
    }

    @Test func fakeHotkeysRegisterFromTheSpecAndReRegister() {
        let hot = FakeThrowHotkeys()
        #expect(hot.registrations.isEmpty)
        hot.start(onThrow: { _ in })                       // convenience start = defaults
        #expect(hot.bindings == .defaults && hot.startCount == 1)
        hot.start(bindings: custom, onThrow: { _ in })
        #expect(hot.bindings == custom && hot.startCount == 2)
        #expect(hot.registrations[9].keyCode == UInt32(kVK_ANSI_T))
        hot.stop()
        #expect(hot.registrations.isEmpty)
    }

    @Test func switchFilterUsesTheConfiguredModifiers() {
        let one = DigitKeys.keyCode(forDigit: 1)!
        #expect(SpaceKeyFilter.digit(keyCode: one, flags: .maskControl, modifiers: .maskControl) == 1)
        #expect(SpaceKeyFilter.digit(keyCode: one, flags: .maskAlternate, modifiers: .maskControl) == nil)
        #expect(SpaceKeyFilter.digit(keyCode: one, flags: [.maskControl, .maskAlternate], modifiers: .maskControl) == nil)
        #expect(SpaceKeyFilter.digit(keyCode: one, flags: .maskAlternate) == 1) // default stays ⌥
        let keys = FakeSpaceKeyObserver()
        var got: [Int] = []
        #expect(keys.start(modifiers: .maskControl) { got.append($0) })
        keys.key(one, flags: .maskControl)
        keys.key(one, flags: .maskAlternate)
        #expect(got == [1] && keys.modifiers == .maskControl)
    }
}

@Suite struct NativeShortcutTests {
    /// What `defaults read com.apple.symbolichotkeys` holds for an enabled Desktop shortcut.
    func entry(key: Int, mask: Int, enabled: Bool = true) -> [String: Any] {
        ["enabled": enabled ? 1 : 0, "value": ["parameters": [65535, key, mask], "type": "standard"]]
    }

    @Test func parsesEnabledShortcutsWithTheirModifiers() {
        let all: [String: Any] = [
            "118": entry(key: 18, mask: 262_144),                  // Desktop 1: ⌃1
            "119": entry(key: 19, mask: 524_288),                  // Desktop 2: ⌥2
            "120": entry(key: 20, mask: 262_144, enabled: false),  // disabled
            "121": entry(key: 99, mask: 262_144),                  // bound to another key
            "126": entry(key: 25, mask: 786_432),                  // Desktop 9: ⌃⌥9
            "7": entry(key: 0, mask: 0),                           // unrelated
        ]
        let parsed = SymbolicHotkeys.parse(all)
        #expect(parsed == [1: .maskControl, 2: .maskAlternate, 9: [.maskControl, .maskAlternate]])
    }

    @Test func malformedEntriesAreSkipped() {
        #expect(SymbolicHotkeys.parse([:]).isEmpty)
        #expect(SymbolicHotkeys.parse(["118": "junk", "119": ["enabled": 1]]).isEmpty)
        #expect(SymbolicHotkeys.parse(["118": ["enabled": 1, "value": ["parameters": [1, 2]]]]).isEmpty)
        #expect(SymbolicHotkeys.parse(["118": entry(key: 18, mask: 0)]).isEmpty) // no modifiers
    }
}

@Suite struct SpaceMoverShortcutTests {
    let frame = rect(100, 100, 800, 600)

    func setup(native: [Int: CGEventFlags]?, fallback: CGEventFlags? = nil, desk deskFlags: CGEventFlags = .maskAlternate)
        -> (FakeDesktop, HyprPlatform.WindowRef, SpaceMover) {
        let desk = makeDesk(spaces: 3)
        desk.nativeSwitchFlags = deskFlags
        let w = desk.addWindow(pid: 100, id: 1, frame: frame)
        desk.focus(w)
        desk.poster.setCursor(CGPoint(x: 1000, y: 800))
        let mover = SpaceMover(ax: desk.ax, spaces: desk.spaces, displays: desk.displays, poster: desk.poster,
                               clock: desk.clock, nativeShortcuts: native.map { FakeNativeSwitchShortcuts($0) })
        if let fallback { mover.fallbackSwitchFlags = fallback }
        return (desk, w, mover)
    }

    @Test func postsTheNativeShortcutsModifiers() throws {
        // symbolichotkeys says ⌃ (262144) for Desktop 2.
        let (desk, w, mover) = setup(native: SymbolicHotkeys.parse(
            ["119": ["enabled": 1, "value": ["parameters": [65535, 19, 262_144]]]]), desk: .maskControl)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.posted.contains(.keyDown(19, .maskControl)))
        #expect(desk.posted.contains(.keyUp(19, .maskControl)))
        #expect(!desk.posted.contains(.keyDown(19, .maskAlternate)))
        #expect(desk.spaces.activeSpace(display: 1) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }

    @Test func usesEachDesktopsOwnShortcut() {
        let (desk, w, mover) = setup(native: [2: .maskControl, 3: [.maskControl, .maskShift]], desk: .maskControl)
        #expect(mover.switchFlags(forDesktop: 2) == .maskControl)
        #expect(mover.switchFlags(forDesktop: 3) == [.maskControl, .maskShift])
        #expect(mover.move(w, toSpace: 2) == .moved)
        _ = desk
    }

    @Test func fallsBackToTheConfiguredSwitchModifiersWhenUnreadable() {
        let (desk, w, mover) = setup(native: [:], fallback: .maskControl, desk: .maskControl)
        #expect(mover.switchFlags(forDesktop: 2) == .maskControl)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.posted.contains(.keyDown(19, .maskControl)))
    }

    @Test func defaultWithoutAReaderIsOption() {
        let (desk, w, mover) = setup(native: nil)
        #expect(mover.fallbackSwitchFlags == .maskAlternate)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(desk.posted.contains(.keyDown(19, .maskAlternate)))
    }

    @Test func aShiftShortcutNeedsNoShiftRelease() {
        let (desk, w, mover) = setup(native: [2: [.maskControl, .maskShift]], desk: [.maskControl, .maskShift])
        desk.holdModifiers([.maskShift, .maskAlternate], releaseAt: desk.clock.now() + 5)
        #expect(mover.move(w, toSpace: 2) == .moved)
        #expect(mover.lastShiftOutcome == .notHeld)
        #expect(desk.posted.contains(.keyDown(19, [.maskControl, .maskShift])))
    }
}

@Suite struct ShortcutConflictTests {
    private func entry(_ enabled: Bool, key: Int, mask: UInt64) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": [65535, key, mask]]]
    }

    @Test func parsesEnabledChordsOnly() {
        let all: [String: Any] = [
            "64": entry(true, key: 49, mask: 1_048_576),            // ⌘Space Spotlight
            "65": entry(false, key: 49, mask: 1_572_864),           // disabled
            "79": entry(true, key: 123, mask: 8_650_752),           // ⌃← (+fn)
            "36": entry(true, key: 103, mask: 8_388_608),           // F11: no real modifier
            "118": entry(true, key: 18, mask: 262_144),             // ⌃1
            "999": entry(true, key: 65535, mask: 262_144),          // no key
            "7": ["enabled": true],                                 // malformed
        ]
        let chords = SymbolicHotkeys.chords(all)
        #expect(chords == [
            SystemChord(modifiers: [.command], keyCode: 49, name: "Spotlight"),
            SystemChord(modifiers: [.control], keyCode: 123, name: "Move left a space"),
            SystemChord(modifiers: [.control], keyCode: 18, name: "Switch to Desktop 1"),
        ])
    }

    @Test func findsClashesForNewAndExistingChordsButNotThePrefix() {
        var keys = KeyBindings.defaults
        keys.actionKeys[.toggleZoom] = KeySpec(parsing: "ctrl+left")
        keys.actionKeys[.equalize] = KeySpec(parsing: "alt+shift+e")
        let system = [
            SystemChord(modifiers: [.option, .shift], keyCode: 3, name: "Spotlight"),     // ⌥⇧F
            SystemChord(modifiers: [.control], keyCode: 123, name: "Move left a space"),
            SystemChord(modifiers: [.option, .shift], keyCode: 18, name: "Desktop 1"),    // ⌥⇧1: the throw prefix
        ]
        let found = ShortcutConflicts.find(in: keys, system: system)
        #expect(found.map(\.action) == ["toggle_float", "toggle_zoom"])
        #expect(found[0].message == "⌥⇧F conflicts with a macOS shortcut (Spotlight)")
        #expect(found[1].message == "⌃LEFT conflicts with a macOS shortcut (Move left a space)")
        #expect(ShortcutConflicts.find(in: keys, system: []).isEmpty)
        keys.suppressedIDs = Set(found.map(\.id))
        let ids = HotkeyCenter.registrations(for: keys).map(\.id)
        #expect(!ids.contains(HotkeyCenter.toggleFloatID) && !ids.contains(HotkeyCenter.hotkeyID(for: .toggleZoom)))
        #expect(ids.contains(HotkeyCenter.hotkeyID(for: .equalize)))
    }
}
