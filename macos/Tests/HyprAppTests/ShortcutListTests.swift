import Testing
import HyprPlatform
@testable import HyprApp

struct ShortcutListTests {
    @Test func formatsGlyphsInModifierOrder() {
        #expect(ShortcutList.format(KeySpec(parsing: "shift+alt+f")!) == "⌥⇧F")
        #expect(ShortcutList.format(KeySpec(parsing: "cmd+shift+ctrl+left")!) == "⌃⇧⌘←")
        #expect(ShortcutList.format(KeySpec(parsing: "alt+space")!) == "⌥Space")
        #expect(ShortcutList.format(KeySpec(parsing: "ctrl+alt+up")!) == "⌃⌥↑")
        #expect(ShortcutList.digits([.option, .shift]) == "⌥⇧1 … ⌥⇧9")
    }

    @Test func defaultsListEveryAction() {
        let rows = ShortcutList.rows(for: .defaults)
        #expect(rows.contains(ShortcutRow(label: "Switch to Desktop N (native macOS shortcut)", chord: "⌥1 … ⌥9")))
        #expect(rows.contains(ShortcutRow(label: "Move the focused window to Desktop N", chord: "⌥⇧1 … ⌥⇧9")))
        #expect(rows.contains(ShortcutRow(label: "Float / tile the focused window", chord: "⌥⇧F")))
        #expect(rows.contains(ShortcutRow(label: "Center the focused window", chord: "⌥⇧C")))
        #expect(rows.contains(ShortcutRow(label: "Focus the window left", chord: "⌥⇧H / ⌥⇧←")))
        #expect(rows.contains(ShortcutRow(label: "Move the window right", chord: "⌥⇧⌘L / ⌥⇧⌘→")))
    }

    @Test func respectsUserConfig() {
        var keys = KeyBindings.defaults
        keys.toggleFloat = KeySpec(parsing: "ctrl+alt+t")!
        keys.throwModifiers = [.control, .option]
        let rows = ShortcutList.rows(for: keys)
        #expect(rows.contains(ShortcutRow(label: "Float / tile the focused window", chord: "⌃⌥T")))
        #expect(rows.contains(ShortcutRow(label: "Move the focused window to Desktop N", chord: "⌃⌥1 … ⌃⌥9")))
        #expect(!rows.contains { $0.chord == "⌥⇧F" })
    }

    @Test func unboundActionsAreOmitted() {
        var keys = KeyBindings.defaults
        keys.focusKeys = []
        keys.switchModifiers = []
        let rows = ShortcutList.rows(for: keys)
        #expect(!rows.contains { $0.label.hasPrefix("Focus") })
        #expect(!rows.contains { $0.label.hasPrefix("Switch") })
    }

    @Test func textAlignsChords() {
        let text = ShortcutList.text(for: [ShortcutRow(label: "A", chord: "⌥1"), ShortcutRow(label: "B", chord: "⌥⇧F")])
        #expect(text == "⌥1    A\n⌥⇧F   B")
    }

    @Test func boundOptInActionsAppearAndUnboundOnesDoNot() throws {
        var keys = KeyBindings.defaults
        #expect(!ShortcutList.rows(for: keys).contains { $0.label == "Zoom the focused window" })
        keys.actionKeys[.toggleZoom] = try #require(KeySpec(parsing: "alt+shift+z"))
        let row = try #require(ShortcutList.rows(for: keys).first { $0.label == "Zoom the focused window" })
        #expect(row.chord == "⌥⇧Z")
    }
}
