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

    @Test func extrasListOnlyBoundOptInActions() throws {
        var keys = KeyBindings.defaults
        #expect(CheatsheetCatalog.extras(for: keys).isEmpty)
        keys.actionKeys[.toggleZoom] = try #require(KeySpec(parsing: "alt+shift+z"))
        #expect(CheatsheetCatalog.extras(for: keys) == [CheatsheetExtra(title: "Zoom the focused window", keys: ["⌥", "⇧", "Z"])])
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
        #expect(CheatsheetCatalog.extras(for: keys).map(\.keys) == [["⌃", "⌥", "Z"]])
    }
}
