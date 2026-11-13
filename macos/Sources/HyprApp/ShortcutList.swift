import HyprPlatform

/// One row of the Keyboard Shortcuts dialog.
struct ShortcutRow: Equatable {
    let label: String
    let chord: String
}

/// Builds the Keyboard Shortcuts rows from the live `KeyBindings`. Each action is one small function
/// returning its rows (none when unbound), so a new action only appends to `rows(for:)`.
enum ShortcutList {
    static func rows(for keys: KeyBindings) -> [ShortcutRow] {
        var rows: [ShortcutRow] = []
        rows += switchDesktop(keys)
        rows += throwWindow(keys)
        rows += toggleFloat(keys)
        rows += centerWindow(keys)
        rows += focus(keys)
        rows += move(keys)
        return rows
    }

    /// Dialog body: one "chord  label" line per row, chords aligned.
    static func text(for rows: [ShortcutRow]) -> String {
        let width = rows.map(\.chord.count).max() ?? 0
        return rows.map { $0.chord + String(repeating: " ", count: width - $0.chord.count + 3) + $0.label }
            .joined(separator: "\n")
    }

    // MARK: actions

    private static func switchDesktop(_ keys: KeyBindings) -> [ShortcutRow] {
        guard !keys.switchModifiers.isEmpty else { return [] }
        return [ShortcutRow(label: "Switch to Desktop N (native macOS shortcut)",
                            chord: digits(keys.switchModifiers))]
    }

    private static func throwWindow(_ keys: KeyBindings) -> [ShortcutRow] {
        guard !keys.throwModifiers.isEmpty else { return [] }
        return [ShortcutRow(label: "Move the focused window to Desktop N", chord: digits(keys.throwModifiers))]
    }

    private static func toggleFloat(_ keys: KeyBindings) -> [ShortcutRow] {
        [ShortcutRow(label: "Float / tile the focused window", chord: format(keys.toggleFloat))]
    }

    private static func centerWindow(_ keys: KeyBindings) -> [ShortcutRow] {
        [ShortcutRow(label: "Center the focused window", chord: format(keys.centerWindow))]
    }

    private static func focus(_ keys: KeyBindings) -> [ShortcutRow] {
        directional(keys.focusKeys, verb: "Focus the window")
    }

    private static func move(_ keys: KeyBindings) -> [ShortcutRow] {
        directional(keys.moveKeys, verb: "Move the window")
    }

    /// One row per direction; alternative keys for the same direction (h / ←) share the row.
    private static func directional(_ keys: [(direction: Direction, spec: KeySpec)], verb: String) -> [ShortcutRow] {
        Direction.allCases.compactMap { dir in
            let chords = keys.filter { $0.direction == dir }.map { format($0.spec) }
            return chords.isEmpty ? nil : ShortcutRow(label: "\(verb) \(dir.rawValue)", chord: chords.joined(separator: " / "))
        }
    }

    // MARK: formatting

    /// "⌥⇧F", "⌃⌥⌘←", "⌥Space": modifiers in ⌃⌥⇧⌘ order, then the key.
    static func format(_ spec: KeySpec) -> String { spec.modifiers.symbols + keyGlyph(spec.key) }

    /// "⌥1 … ⌥9" style range for a modifier set + digit keys.
    static func digits(_ mods: KeyModifiers) -> String { "\(mods.symbols)1 … \(mods.symbols)9" }

    static func keyGlyph(_ key: String) -> String {
        glyphs[key] ?? key.uppercased()
    }

    private static let glyphs: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "space": "Space", "tab": "⇥", "return": "↩", "escape": "⎋",
        "grave": "`", "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/",
    ]
}
