import Carbon.HIToolbox
import CoreGraphics

/// Modifier keys of a shortcut. Pure value type: names ↔ Carbon masks ↔ `CGEventFlags`.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)

    /// Parses `"alt+shift"` (case-insensitive; alt/opt/option, shift, ctrl/control, cmd/command).
    /// Nil for an empty text, an unknown name or a duplicate.
    public init?(parsing text: String) {
        var mods: KeyModifiers = []
        for part in text.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            guard let m = Self.byName[String(part)], !mods.contains(m) else { return nil }
            mods.insert(m)
        }
        guard !mods.isEmpty else { return nil }
        self = mods
    }

    private static let byName: [String: KeyModifiers] = [
        "alt": .option, "opt": .option, "option": .option, "shift": .shift,
        "ctrl": .control, "control": .control, "cmd": .command, "command": .command,
    ]

    /// `RegisterEventHotKey` modifier mask.
    public var carbon: UInt32 {
        var m = 0
        if contains(.control) { m |= controlKey }
        if contains(.option) { m |= optionKey }
        if contains(.shift) { m |= shiftKey }
        if contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    public var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    public init(cgFlags f: CGEventFlags) {
        var m: KeyModifiers = []
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskCommand) { m.insert(.command) }
        self = m
    }

    /// "⌃⌥⇧⌘" order, for messages.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A shortcut: modifiers plus one key (`toggle_float`).
public struct KeySpec: Equatable, Sendable {
    public var modifiers: KeyModifiers
    /// Canonical lower-case name (`"f"`, `"space"`, `"f5"` …).
    public var key: String
    public var keyCode: UInt32

    public init?(modifiers: KeyModifiers, key: String) {
        guard !modifiers.isEmpty, let code = Self.keyCodes[key.lowercased()] else { return nil }
        self.modifiers = modifiers
        self.key = key.lowercased()
        self.keyCode = code
    }

    /// Parses `"alt+shift+f"` (exactly one key, at least one modifier).
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let key = parts.last,
              let mods = KeyModifiers(parsing: parts.dropLast().joined(separator: "+")) else { return nil }
        self.init(modifiers: mods, key: key)
    }

    /// "⌥⇧F".
    public var display: String { modifiers.symbols + key.uppercased() }

    /// ANSI virtual key codes of every key name the config grammar accepts.
    public static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
        "space": 49, "tab": 48, "return": 36, "escape": 53, "grave": 50, "minus": 27, "equal": 24,
        "comma": 43, "period": 47, "slash": 44,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}

/// Direction in 2D space for BSP tree focus and window movement.
public enum Direction: String, CaseIterable, Sendable {
    case left, down, up, right
}

/// Opt-in actions (`config.keys.<rawValue>`): unbound by default except `rotate_split` (⌥⇧R); order = hotkey id order.
public enum KeyAction: String, CaseIterable, Sendable {
    case resizeLeft = "resize_left", resizeDown = "resize_down", resizeUp = "resize_up", resizeRight = "resize_right"
    case equalize
    case rotateSplit = "rotate_split"
    case toggleZoom = "toggle_zoom"
    case moveDisplayNext = "move_display_next", moveDisplayPrev = "move_display_prev"
    case togglePause = "toggle_pause"
}

/// The configurable shortcuts (`config.keys`).
public struct KeyBindings: Equatable, Sendable {
    /// Modifiers + digit 1–9: throw the focused window to that Desktop.
    public var throwModifiers: KeyModifiers
    /// Modifiers + `toggle_float`'s key: float / tile the focused window.
    public var toggleFloat: KeySpec
    /// Modifiers hyprMac listens for with 1–9 (the native "Switch to Desktop N" shortcut).
    public var switchModifiers: KeyModifiers

    /// Prefix for native navigation and window operations (default: opt + shift).
    public var prefix: KeyModifiers
    /// Center the window (default: pref + c, i.e. ⌥⇧C).
    public var centerWindow: KeySpec
    /// Move focus in the BSP tree (pref + h/j/k/l and pref + arrow keys, i.e. ⌥⇧H/J/K/L, ⌥⇧←/↓/↑/→).
    public var focusKeys: [(direction: Direction, spec: KeySpec)]
    /// Move windows in the BSP tree (pref + cmd + h/j/k/l and pref + cmd + arrow keys, i.e. ⌥⇧⌘H/J/K/L, ⌥⇧⌘←/↓/↑/→).
    public var moveKeys: [(direction: Direction, spec: KeySpec)]
    /// Opt-in actions that have a shortcut: `rotate_split` (prefix + R) by default, plus whatever the user bound
    /// (`keys.resize_left`, `keys.toggle_zoom`, …).
    public var actionKeys: [KeyAction: KeySpec] = [:]
    /// Hotkey ids not to register because their chord clashes with a macOS shortcut (`ShortcutConflicts`).
    public var suppressedIDs: Set<UInt32> = []

    public init(
        throwModifiers: KeyModifiers,
        toggleFloat: KeySpec,
        switchModifiers: KeyModifiers,
        prefix: KeyModifiers = [.option, .shift],
        centerWindow: KeySpec? = nil,
        focusKeys: [(direction: Direction, spec: KeySpec)]? = nil,
        moveKeys: [(direction: Direction, spec: KeySpec)]? = nil
    ) {
        self.throwModifiers = throwModifiers
        self.toggleFloat = toggleFloat
        self.switchModifiers = switchModifiers
        self.prefix = prefix
        self.centerWindow = centerWindow ?? KeySpec(modifiers: prefix, key: "c")!
        self.actionKeys = [.rotateSplit: KeySpec(modifiers: prefix, key: "r")!]
        let moveMods = prefix.contains(.shift) ? prefix.union(.command) : prefix.union(.shift)
        self.focusKeys = focusKeys ?? [
            (.left, KeySpec(modifiers: prefix, key: "h")!),
            (.left, KeySpec(modifiers: prefix, key: "left")!),
            (.down, KeySpec(modifiers: prefix, key: "j")!),
            (.down, KeySpec(modifiers: prefix, key: "down")!),
            (.up, KeySpec(modifiers: prefix, key: "k")!),
            (.up, KeySpec(modifiers: prefix, key: "up")!),
            (.right, KeySpec(modifiers: prefix, key: "l")!),
            (.right, KeySpec(modifiers: prefix, key: "right")!),
        ]
        self.moveKeys = moveKeys ?? [
            (.left, KeySpec(modifiers: moveMods, key: "h")!),
            (.left, KeySpec(modifiers: moveMods, key: "left")!),
            (.down, KeySpec(modifiers: moveMods, key: "j")!),
            (.down, KeySpec(modifiers: moveMods, key: "down")!),
            (.up, KeySpec(modifiers: moveMods, key: "k")!),
            (.up, KeySpec(modifiers: moveMods, key: "up")!),
            (.right, KeySpec(modifiers: moveMods, key: "l")!),
            (.right, KeySpec(modifiers: moveMods, key: "right")!),
        ]
    }

    public static func == (a: KeyBindings, b: KeyBindings) -> Bool {
        a.throwModifiers == b.throwModifiers
            && a.toggleFloat == b.toggleFloat
            && a.switchModifiers == b.switchModifiers
            && a.prefix == b.prefix
            && a.centerWindow == b.centerWindow
            && a.focusKeys.count == b.focusKeys.count
            && zip(a.focusKeys, b.focusKeys).allSatisfy { $0.direction == $1.direction && $0.spec == $1.spec }
            && a.moveKeys.count == b.moveKeys.count
            && zip(a.moveKeys, b.moveKeys).allSatisfy { $0.direction == $1.direction && $0.spec == $1.spec }
            && a.actionKeys == b.actionKeys
            && a.suppressedIDs == b.suppressedIDs
    }

    /// Equal to the default shortcuts: ⌥⇧1–9, ⌥⇧F, ⌥1–9, ⌃⌥C, ⌃⌥H/J/K/L+arrows, ⌃⌥⇧H/J/K/L+arrows.
    public static let defaults = KeyBindings(
        throwModifiers: [.option, .shift],
        toggleFloat: KeySpec(modifiers: [.option, .shift], key: "f")!,
        switchModifiers: [.option])

    /// Opens the shortcuts cheatsheet: prefix + `/` (⌥⇧/, the key labelled "?"). Not configurable.
    public var showShortcuts: KeySpec { KeySpec(modifiers: prefix, key: "slash")! }

    /// From the canonical strings of `hm_config_load_extras`.
    public init?(throw t: String, toggleFloat f: String, switch s: String) {
        guard let t = KeyModifiers(parsing: t), let f = KeySpec(parsing: f), let s = KeyModifiers(parsing: s) else { return nil }
        self.init(throwModifiers: t, toggleFloat: f, switchModifiers: s)
    }
}
