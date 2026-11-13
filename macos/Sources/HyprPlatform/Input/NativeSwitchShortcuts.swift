import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The user's native "Switch to Desktop N" shortcuts (`com.apple.symbolichotkeys`, ids 118–126).
public protocol NativeSwitchShortcuts: AnyObject {
    /// Modifiers of every ENABLED shortcut whose key is the digit key itself, by digit 1–9.
    func enabledModifiers() -> [Int: CGEventFlags]
    /// Every ENABLED macOS shortcut with a key and at least one modifier (conflict check).
    func enabledChords() -> [SystemChord]
}

public extension NativeSwitchShortcuts {
    func enabledChords() -> [SystemChord] { [] }
}

/// One enabled entry of `com.apple.symbolichotkeys` as a chord.
public struct SystemChord: Equatable, Hashable, Sendable {
    public var modifiers: KeyModifiers
    public var keyCode: UInt32
    public var name: String
    public init(modifiers: KeyModifiers, keyCode: UInt32, name: String) {
        self.modifiers = modifiers; self.keyCode = keyCode; self.name = name
    }
}

public enum SymbolicHotkeys {
    /// "Switch to Desktop 1" is id 118, … Desktop 9 is 126.
    public static let firstDesktopID = 118
    public static let domain = "com.apple.symbolichotkeys"

    /// Pure parser of the `AppleSymbolicHotKeys` dictionary. `parameters` is
    /// `(ascii, key code, modifier mask)`; the mask uses the `CGEventFlags` bit values
    /// (524288 = ⌥, 262144 = ⌃, 131072 = ⇧, 1048576 = ⌘). Disabled entries, entries bound to a
    /// key other than the digit's own, and malformed ones are skipped.
    public static func parse(_ all: [String: Any]) -> [Int: CGEventFlags] {
        var out: [Int: CGEventFlags] = [:]
        for n in 1...9 {
            guard let entry = all[String(firstDesktopID + n - 1)] as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let key = (params[1] as? NSNumber)?.intValue,
                  let mask = (params[2] as? NSNumber)?.uint64Value,
                  key == DigitKeys.keyCode(forDigit: n).map({ Int($0) }) else { continue }
            let flags = CGEventFlags(rawValue: mask).intersection(SpaceKeyFilter.relevantModifiers)
                .subtracting(.maskSecondaryFn)
            guard !flags.isEmpty else { continue }
            out[n] = flags
        }
        return out
    }

    /// Short names of well-known entries, for the conflict message.
    static let names: [Int: String] = [
        7: "Move focus to menu bar", 8: "Move focus to Dock", 9: "Move focus to next window",
        10: "Move focus to window toolbar", 11: "Move focus to floating window", 12: "Keyboard access",
        13: "Tab focus mode", 15: "Zoom", 17: "Zoom in", 19: "Zoom out", 21: "Image smoothing",
        25: "Increase contrast", 26: "Decrease contrast", 27: "Move focus to next window in app",
        28: "Screenshot", 29: "Screenshot to clipboard", 30: "Screenshot of selection",
        31: "Screenshot of selection to clipboard", 32: "Mission Control", 33: "Application windows",
        34: "Mission Control", 35: "Application windows", 36: "Show Desktop", 37: "Show Desktop",
        52: "Dock hiding", 57: "Move focus to status menus", 59: "VoiceOver", 60: "Previous input source",
        61: "Next input source", 64: "Spotlight", 65: "Finder search", 79: "Move left a space",
        81: "Move right a space", 98: "Help menu", 160: "Launchpad", 184: "Screenshot options",
        190: "Quick Note",
    ]

    /// Pure parser: every ENABLED entry with a real key code (not 65535) and at least one of ⌃⌥⇧⌘.
    /// Malformed and disabled entries are skipped. Sorted by id so results are deterministic.
    public static func chords(_ all: [String: Any]) -> [SystemChord] {
        var out: [SystemChord] = []
        for (idText, raw) in all.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            guard let id = Int(idText), let entry = raw as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let key = (params[1] as? NSNumber)?.intValue, key >= 0, key < 0xFFFF,
                  let mask = (params[2] as? NSNumber)?.uint64Value else { continue }
            let mods = KeyModifiers(cgFlags: CGEventFlags(rawValue: mask))
            guard !mods.isEmpty else { continue }
            let name: String
            if (firstDesktopID...firstDesktopID + 8).contains(id) { name = "Switch to Desktop \(id - firstDesktopID + 1)" }
            else { name = names[id] ?? "System Settings ▸ Keyboard Shortcuts" }
            out.append(SystemChord(modifiers: mods, keyCode: UInt32(key), name: name))
        }
        return out
    }
}

/// A configured chord that a macOS shortcut already owns.
public struct ShortcutConflict: Equatable, Sendable {
    public var id: UInt32
    public var action: String
    public var chord: String
    public var system: String
    /// "⌥⇧F conflicts with a macOS shortcut (Spotlight)".
    public var message: String { "\(chord) conflicts with a macOS shortcut (\(system))" }
}

public enum ShortcutConflicts {
    /// Compares every configured chord (the throw prefix + digits excluded) with `system`.
    public static func find(in bindings: KeyBindings, system: [SystemChord]) -> [ShortcutConflict] {
        var out: [ShortcutConflict] = []
        for c in HotkeyCenter.namedChords(for: bindings) {
            guard let hit = system.first(where: { $0.keyCode == c.spec.keyCode && $0.modifiers == c.spec.modifiers })
            else { continue }
            out.append(ShortcutConflict(id: c.id, action: c.name, chord: c.spec.display, system: hit.name))
        }
        return out
    }
}

/// Reads the preferences read-only on every call, so a change in System Settings applies at once.
public final class SystemNativeSwitchShortcuts: NativeSwitchShortcuts {
    public init() {}

    public func enabledModifiers() -> [Int: CGEventFlags] {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, SymbolicHotkeys.domain as CFString)
        return SymbolicHotkeys.parse(value as? [String: Any] ?? [:])
    }

    public func enabledChords() -> [SystemChord] {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, SymbolicHotkeys.domain as CFString)
        return SymbolicHotkeys.chords(value as? [String: Any] ?? [:])
    }
}

public final class FakeNativeSwitchShortcuts: NativeSwitchShortcuts {
    public var shortcuts: [Int: CGEventFlags]
    public var chords: [SystemChord]
    public init(_ shortcuts: [Int: CGEventFlags] = [:], chords: [SystemChord] = []) {
        self.shortcuts = shortcuts; self.chords = chords
    }
    public func enabledModifiers() -> [Int: CGEventFlags] { shortcuts }
    public func enabledChords() -> [SystemChord] { chords }
}
