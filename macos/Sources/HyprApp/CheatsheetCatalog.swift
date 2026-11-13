import HyprPlatform

/// One illustrated row of the shortcuts cheatsheet.
struct CheatsheetEntry: Equatable, Identifiable {
    /// Which animation illustrates the shortcut.
    enum Illustration: String, CaseIterable {
        case switchDesktop, throwWindow, focus, swap, toggleFloat, center, help
    }

    var id: Illustration { illustration }
    let illustration: Illustration
    let title: String
    let detail: String
    /// Alternative ways to press it; each alternative is a row of keycaps ("⌥", "⇧", "H").
    let keys: [[String]]
}

/// A compact, un-animated row for a bound opt-in action (resize, zoom, …).
struct CheatsheetExtra: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let keys: [String]
}

/// What the cheatsheet lists, derived from the live key bindings so it never goes stale.
/// Anything unbound is left out, like in `ShortcutList`.
enum CheatsheetCatalog {
    static func entries(for keys: KeyBindings) -> [CheatsheetEntry] {
        var list: [CheatsheetEntry] = []
        if !keys.switchModifiers.isEmpty {
            list.append(.init(illustration: .switchDesktop, title: "Switch desktop", detail: "Jump to Desktop N",
                              keys: [caps(keys.switchModifiers) + ["1–9"]]))
        }
        if !keys.throwModifiers.isEmpty {
            list.append(.init(illustration: .throwWindow, title: "Throw window",
                              detail: "Send the focused window to Desktop N",
                              keys: [caps(keys.throwModifiers) + ["1–9"]]))
        }
        let focus = directional(keys.focusKeys)
        if !focus.isEmpty {
            list.append(.init(illustration: .focus, title: "Move focus", detail: "Focus the neighbouring tile", keys: focus))
        }
        let move = directional(keys.moveKeys)
        if !move.isEmpty {
            list.append(.init(illustration: .swap, title: "Swap windows",
                              detail: "Trade places with the neighbouring tile", keys: move))
        }
        list.append(.init(illustration: .toggleFloat, title: "Float / tile",
                          detail: "Pop the window out of the layout, or back in", keys: [caps(keys.toggleFloat)]))
        list.append(.init(illustration: .center, title: "Center window",
                          detail: "Float the window in the middle of the screen", keys: [caps(keys.centerWindow)]))
        list.append(.init(illustration: .help, title: "This cheatsheet",
                          detail: "Press again or Esc to close", keys: [caps(keys.showShortcuts)]))
        return list
    }

    /// The opt-in actions the user has bound, in `KeyAction` order.
    static func extras(for keys: KeyBindings) -> [CheatsheetExtra] {
        KeyAction.allCases.compactMap { action in
            keys.actionKeys[action].map { CheatsheetExtra(title: ShortcutList.label(for: action), keys: caps($0)) }
        }
    }

    /// Keycaps of a modifier set, in ⌃⌥⇧⌘ order.
    static func caps(_ modifiers: KeyModifiers) -> [String] { modifiers.symbols.map(String.init) }

    /// Keycaps of a shortcut: its modifiers, then the key.
    static func caps(_ spec: KeySpec) -> [String] { caps(spec.modifiers) + [ShortcutList.keyGlyph(spec.key)] }

    /// Collapses direction bindings into "⌥⇧ H J K L" / "⌥⇧ ← ↓ ↑ →" when they share modifiers,
    /// else lists each binding on its own.
    static func directional(_ items: [(direction: Direction, spec: KeySpec)]) -> [[String]] {
        let order: [Direction] = [.left, .down, .up, .right]
        let sorted = items.sorted { (order.firstIndex(of: $0.direction) ?? 0) < (order.firstIndex(of: $1.direction) ?? 0) }
        let arrows: Set<String> = ["left", "right", "up", "down"]
        var result: [[String]] = []
        for isArrow in [false, true] {
            let group = sorted.filter { arrows.contains($0.spec.key) == isArrow }
            guard let first = group.first else { continue }
            if group.allSatisfy({ $0.spec.modifiers == first.spec.modifiers }) {
                result.append(caps(first.spec.modifiers) + group.map { ShortcutList.keyGlyph($0.spec.key) })
            } else {
                result += group.map { caps($0.spec) }
            }
        }
        return result
    }
}
