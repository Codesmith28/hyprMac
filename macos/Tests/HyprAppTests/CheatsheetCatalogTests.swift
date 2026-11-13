import Testing
import Foundation
import HyprKit
import HyprPlatform
@testable import HyprApp

struct CheatsheetCatalogTests {
    private func entry(_ i: CheatsheetEntry.Illustration, _ keys: KeyBindings = .defaults) -> CheatsheetEntry? {
        CheatsheetCatalog.entries(for: keys).first { $0.illustration == i }
    }

    @Test func listsEveryIllustrationOnce() {
        #expect(CheatsheetCatalog.entries(for: .defaults).map(\.illustration) == CheatsheetEntry.Illustration.allCases)
    }

    @Test func defaultsRenderAsKeycaps() {
        #expect(entry(.switchDesktop)?.keys == [["⌥", "1–9"]])
        #expect(entry(.throwWindow)?.keys == [["⌥", "⇧", "1–9"]])
        #expect(entry(.toggleFloat)?.keys == [["⌥", "⇧", "F"]])
        #expect(entry(.center)?.keys == [["⌥", "⇧", "C"]])
        #expect(entry(.focus)?.keys == [["⌥", "⇧", "H/J/K/L"], ["⌥", "⇧", "←/↓/↑/→"]])
        #expect(entry(.swap)?.keys == [["⌥", "⇧", "⌘", "H/J/K/L"], ["⌥", "⇧", "⌘", "←/↓/↑/→"]])
        #expect(entry(.reSplit)?.keys == [["⇧", "Drop"]])
        #expect(entry(.help)?.keys == [["⌥", "⇧", "/"]])
    }

    @Test func followsCustomBindings() {
        var keys = KeyBindings.defaults
        keys.toggleFloat = KeySpec(parsing: "ctrl+alt+g")!
        keys.focusKeys = [(.left, KeySpec(parsing: "ctrl+h")!), (.right, KeySpec(parsing: "alt+l")!)]
        #expect(entry(.toggleFloat, keys)?.keys == [["⌃", "⌥", "G"]])
        // Mixed modifiers can't be collapsed, so each binding gets its own row.
        #expect(entry(.focus, keys)?.keys == [["⌃", "H"], ["⌥", "L"]])
    }

    @Test func unboundShortcutsAreOmitted() {
        var keys = KeyBindings.defaults
        keys.switchModifiers = []
        keys.focusKeys = []
        #expect(entry(.switchDesktop, keys) == nil)
        #expect(entry(.focus, keys) == nil)
        #expect(entry(.swap, keys) != nil)
    }

    private func extra(_ title: String, _ keys: KeyBindings = .defaults) -> CheatsheetExtra.Binding? {
        CheatsheetCatalog.extras(for: keys).first { $0.title == title }?.binding
    }

    /// Nothing is hidden: every opt-in action shows up, unbound ones with the config key to set.
    @Test func extrasListEveryActionBoundOrNot() throws {
        var keys = KeyBindings.defaults
        let all = CheatsheetCatalog.extras(for: keys)
        for action in KeyAction.allCases {
            #expect(all.contains { $0.title == CheatsheetCatalog.shortTitle(for: action) }, "\(action) missing")
            if action != .rotateSplit { #expect(all.contains { $0.binding == .unbound(configKey: action.rawValue) }) }
        }
        #expect(extra("Flip split") == .keys(["⌥", "⇧", "R"]))  // the one opt-in action with a default key
        #expect(extra("Zoom window") == .unbound(configKey: "toggle_zoom"))
        keys.actionKeys[.rotateSplit] = try #require(KeySpec(parsing: "ctrl+alt+r"))
        keys.actionKeys[.toggleZoom] = try #require(KeySpec(parsing: "alt+shift+z"))
        #expect(extra("Flip split", keys) == .keys(["⌃", "⌥", "R"]))
        #expect(extra("Zoom window", keys) == .keys(["⌥", "⇧", "Z"]))
        #expect(extra("Equalize splits", keys) == .unbound(configKey: "equalize"))
    }

    @Test func extrasIncludeMouseGestures() {
        #expect(extra("Resize a tile") == .gesture("drag its edge"))
        #expect(extra("Swap tiles") == .gesture("drop on a tile"))
    }

    @Test func helpShortcutIsPrefixSlash() {
        #expect(KeyBindings.defaults.showShortcuts.keyCode == 44)
        #expect(KeyBindings.defaults.showShortcuts.modifiers == [.option, .shift])
    }

    /// The real path: init.lua -> ConfigStore (what the coordinator uses) -> cheatsheet.
    @Test func followsInitLua() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cheatsheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("init.lua")
        try """
        config = { keys = { toggle_float = "ctrl+alt+g", focus_left = "ctrl+alt+a", focus_down = "ctrl+alt+s",
                            focus_up = "ctrl+alt+w", focus_right = "ctrl+alt+d", toggle_zoom = "ctrl+alt+z" } }
        """.write(to: file, atomically: true, encoding: .utf8)

        let store = ConfigStore(path: file)
        guard case .loaded = store.load() else { Issue.record("init.lua did not load"); return }
        let keys = store.current.keys
        #expect(entry(.toggleFloat, keys)?.keys == [["⌃", "⌥", "G"]])
        #expect(entry(.focus, keys)?.keys == [["⌃", "⌥", "A/S/W/D"], ["⌃", "⌥", "←/↓/↑/→"]])
        #expect(extra("Zoom window", keys) == .keys(["⌃", "⌥", "Z"]))
    }
}
