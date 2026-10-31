import AppKit

// ⌥⇧F toggles the focused window between floating and tiled. Posts a synthetic key, so it is
// only run by the orchestrator under supervision (like every real scenario).

extension Catalog {
    /// kVK_ANSI_F.
    static let keyF: CGKeyCode = 3

    static let toggleFloat = Scenario(
        name: "toggle-float",
        summary: "⌥⇧F floats window 2 at its original size, centred (others tile as 2); again → 3 tiles") { ctx in
        try ctx.startHypr()
        let log = try ctx.log
        let f = try ctx.launchFixture(3, ["--size", "640x420"])
        let r = try (0..<3).map(f.ref)
        guard let orig = f.originalFrame(1) else { throw HarnessError("fixture did not report window 1's frame") }
        try ctx.expectOracle(r, "3 windows tiled before the toggle")

        func toggle(_ expect: String) throws {
            try f.focusAndWait(1)
            let c = log.cursor
            Keys.post(keyF, flags: [.maskAlternate, .maskShift])
            guard let ev = log.waitFor("toggle_float", after: c, timeout: 5) else {
                throw HarnessError("⌥⇧F produced no toggle_float event (hotkey taken or not registered?)", details: log.tail())
            }
            guard ev.string("state") == expect else {
                throw HarnessError("toggle_float reported state=\(ev.string("state") ?? "nil"); expected \(expect)", details: [ev.raw])
            }
        }

        // Tiled → floating: original size, centred on the usable rect; the other two tile as 2.
        try toggle("floating")
        let usable = ctx.screen.visible
        let want = CGRect(x: usable.midX - orig.width / 2, y: usable.midY - orig.height / 2,
                          width: orig.width, height: orig.height)
        try ctx.expectFrames([r[1]], "window 2 floats at its original \(fmt(orig.width))×\(fmt(orig.height)) size, centred") { m in
            guard let b = m[0].best else { return ["window 2 was not measurable"] }
            var p: [String] = []
            if abs(b.width - want.width) > 1 || abs(b.height - want.height) > 1 {
                p.append("window 2 is \(fmt(b.width))×\(fmt(b.height)); expected \(fmt(want.width))×\(fmt(want.height))")
            }
            if abs(b.midX - want.midX) > 1 || abs(b.midY - want.midY) > 1 {
                p.append("window 2 is centred at (\(fmt(b.midX)), \(fmt(b.midY))); expected (\(fmt(want.midX)), \(fmt(want.midY)))")
            }
            return p
        }
        try ctx.expectOracle([r[0], r[2]], "windows 1 and 3 tile as 2")

        // Floating → tiled: back to 3 tiles.
        try toggle("tiled")
        try ctx.expectOracle(r, "3 windows tiled again after the second toggle")
    }
}
