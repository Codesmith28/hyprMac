import AppKit

// config.keys: the toggle-float shortcut is rebound in the config file. Posts synthetic keys, so it
// is only run by the orchestrator under supervision (like every real scenario).

extension Catalog {
    /// kVK_ANSI_T.
    static let keyT: CGKeyCode = 17

    static let customKeys = Scenario(
        name: "custom-keys",
        summary: "toggle_float = ctrl+alt+t: that combo floats window 2; the old ⌥⇧F no longer does") { ctx in
        try ctx.startHypr(extraConfig: "keys = { toggle_float = \"ctrl+alt+t\" },")
        let log = try ctx.log
        let f = try ctx.launchFixture(3, ["--size", "640x420"])
        let r = try (0..<3).map(f.ref)
        try ctx.expectOracle(r, "3 windows tiled before the toggle")

        // The old shortcut is unbound: no toggle_float within a second.
        try f.command("focus 1")
        pump(0.3)
        var c = log.cursor
        Keys.post(keyF, flags: [.maskAlternate, .maskShift])
        if log.waitFor("toggle_float", after: c, timeout: 1) != nil {
            throw HarnessError("⌥⇧F still toggled although toggle_float was rebound to ctrl+alt+t", details: log.tail())
        }

        // The configured combo toggles.
        try f.command("focus 1")
        pump(0.3)
        c = log.cursor
        Keys.post(keyT, flags: [.maskControl, .maskAlternate])
        guard let ev = log.waitFor("toggle_float", after: c, timeout: 5) else {
            throw HarnessError("ctrl+alt+t produced no toggle_float event (hotkey taken or not registered?)",
                               details: log.tail())
        }
        guard ev.string("state") == "floating" else {
            throw HarnessError("toggle_float reported state=\(ev.string("state") ?? "nil"); expected floating", details: [ev.raw])
        }
        try ctx.expectOracle([r[1], r[2]], "windows 2 and 3 tile as 2 once window 1 floats")
    }
}
