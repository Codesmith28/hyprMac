import HyprPlatform

/// One illustrated row of the shortcuts cheatsheet.
struct CheatsheetEntry: Equatable, Identifiable {
    /// Which animation illustrates the shortcut.
    enum Illustration: String, CaseIterable {
        case switchDesktop, throwWindow, focus, swap, reSplit, toggleFloat, center, help
    }

    var id: Illustration { illustration }
    let illustration: Illustration
    let title: String
    let detail: String
    /// Alternative ways to press it; each alternative is a row of keycaps ("⌥", "⇧", "H").
    let keys: [[String]]
}

/// A compact, un-animated cell: an opt-in action (resize, flip split, zoom, …) or a mouse gesture.
struct CheatsheetExtra: Equatable, Identifiable {
    enum Binding: Equatable {
        /// Bound: the keycaps.
        case keys([String])
        /// Ships unbound: the `keys.<name>` entry that binds it in init.lua.
        case unbound(configKey: String)
        /// A mouse gesture: how to do it.
        case gesture(String)
    }
    var id: String { title }
    let title: String
    let binding: Binding
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
        list.append(.init(illustration: .reSplit, title: "Re-split a tile",
                          detail: "Drop on a tile's edge: side by side or stacked. Menu: Flip Split",
                          keys: [["⇧", "Drop"]]))
        list.append(.init(illustration: .toggleFloat, title: "Float / tile",
                          detail: "Pop the window out of the layout, or back in", keys: [caps(keys.toggleFloat)]))
        list.append(.init(illustration: .center, title: "Center window",
                          detail: "Float the window in the middle of the screen", keys: [caps(keys.centerWindow)]))
        list.append(.init(illustration: .help, title: "This cheatsheet",
                          detail: "Press again or Esc to close", keys: [caps(keys.showShortcuts)]))
        return list
    }

    /// Every opt-in action in `KeyAction` order (bound ones show their keys, the rest the `keys.<name>`
    /// to set), then the mouse gestures, so nothing hyprMac can do is missing from the cheatsheet.
    static func extras(for keys: KeyBindings) -> [CheatsheetExtra] {
        let actions = KeyAction.allCases.map { action in
            CheatsheetExtra(title: shortTitle(for: action),
                            binding: keys.actionKeys[action].map { .keys(caps($0)) } ?? .unbound(configKey: action.rawValue))
        }
        return actions + [
            CheatsheetExtra(title: "Resize a tile", binding: .gesture("drag its edge")),
            CheatsheetExtra(title: "Swap tiles", binding: .gesture("drop on a tile")),
        ]
    }

    /// Short names that fit a compact cell.
    static func shortTitle(for action: KeyAction) -> String {
        switch action {
        case .resizeLeft: "Resize left"
        case .resizeDown: "Resize down"
        case .resizeUp: "Resize up"
        case .resizeRight: "Resize right"
        case .equalize: "Equalize splits"
        case .rotateSplit: "Flip split"
        case .toggleZoom: "Zoom window"
        case .moveDisplayNext: "Next display"
        case .moveDisplayPrev: "Prev display"
        case .togglePause: "Pause tiling"
        }
    }

    /// Keycaps of a modifier set, in ⌃⌥⇧⌘ order.
    static func caps(_ modifiers: KeyModifiers) -> [String] { modifiers.symbols.map(String.init) }

    /// Keycaps of a shortcut: its modifiers, then the key.
    static func caps(_ spec: KeySpec) -> [String] { caps(spec.modifiers) + [ShortcutList.keyGlyph(spec.key)] }

    /// Collapses direction bindings into one keycap per family, "⌥⇧ [H/J/K/L]" and "⌥⇧ [←/↓/↑/→]"
    /// (press any one), when they share modifiers; else lists each binding on its own.
    static func directional(_ items: [(direction: Direction, spec: KeySpec)]) -> [[String]] {
        let order: [Direction] = [.left, .down, .up, .right]
        let sorted = items.sorted { (order.firstIndex(of: $0.direction) ?? 0) < (order.firstIndex(of: $1.direction) ?? 0) }
        let arrows: Set<String> = ["left", "right", "up", "down"]
        var result: [[String]] = []
        for isArrow in [false, true] {
            let group = sorted.filter { arrows.contains($0.spec.key) == isArrow }
            guard let first = group.first else { continue }
            if group.allSatisfy({ $0.spec.modifiers == first.spec.modifiers }) {
                result.append(caps(first.spec.modifiers) + [group.map { ShortcutList.keyGlyph($0.spec.key) }.joined(separator: "/")])
            } else {
                result += group.map { caps($0.spec) }
            }
        }
        return result
    }
}
