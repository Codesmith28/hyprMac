import AppKit

/// The scenario catalogue. Each one starts its own hyprMac and fixtures and
/// relies on `Context.cleanup()` to quit them.
enum Catalog {
    static let all: [Scenario] = tiles + [
        closeReflow, reopen, minSize, nonResizableFloats, toggleFloat,
        auxIgnored("sheet"), auxIgnored("panel"), auxIgnored("dialog"),
        tabsDedupe, minimizeRestore, hideRestore, fullscreenRestore,
        hungAppIsolation, snapBackNoLoop, lateWindow,
        throwToSpace2, throwHeldModifiers, throwTitlebarVariants, throwNoSpace, throwAlreadyThere,
        throwRapid, missingSpaceNotice, displayCache, configReload, badConfigSurvives,
    ]

    static func named(_ name: String) -> Scenario? { all.first { $0.name == name } }

    // MARK: 1. exact layouts

    static let tiles: [Scenario] = [1, 2, 3, 5, 8].map { n in
        Scenario(name: "tile-\(n)", summary: "\(n) window(s) match the oracle's dwindle layout") { ctx in
            try ctx.startHypr()
            let f = try ctx.launchFixture(n)
            let refs = try (0..<n).map(f.ref)
            let smallest = ctx.oracle(n)[0].map { min($0.width, $0.height) }.min() ?? 0
            if smallest < 80 {
                ctx.note("smallest expected tile is \(fmt(smallest)) pt; AppKit's titled-window minimum may refuse it")
            }
            try ctx.expectOracle(refs, "\(n) windows")
        }
    }

    // MARK: 2–3. close / reopen

    static let closeReflow = Scenario(name: "close-reflow",
                                      summary: "closing the middle of 3 reflows to the 2-window layout") { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(3)
        let r = try (0..<3).map(f.ref)
        try ctx.expectOracle(r, "3 windows before close")
        try f.command("close 1")
        try ctx.expectOracle([r[0], r[2]], "2 windows after closing window 1")
    }

    static let reopen = Scenario(name: "reopen", summary: "close then open again retiles both ways") { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(2)
        let r = try (0..<2).map(f.ref)
        try ctx.expectOracle(r, "2 windows")
        try f.command("close 1")
        try ctx.expectOracle([r[0]], "1 window after close")
        let ack = try f.command("open")
        guard let idx = (ack["index"] as? NSNumber)?.intValue else { throw HarnessError("open ack has no index") }
        try ctx.expectOracle([r[0], try f.ref(idx)], "2 windows after reopen")
    }

    // MARK: 4–5. size constraints

    static let minSize = Scenario(name: "min-size",
                                  summary: "a min-width-900 window in a 2-tile split stays sane") { ctx in
        let minW = 900.0
        try ctx.startHypr()
        let log = try ctx.log
        let c = log.cursor
        let f = try ctx.launchFixture(2, ["--min-size", "\(Int(minW))x100@1"])
        let root = ctx.screen.visible.insetBy(dx: ctx.gaps.outer, dy: ctx.gaps.outer)
        if root.width < minW + ctx.gaps.inner + 100 {
            throw SkipScenario(reason: "usable width \(fmt(root.width)) pt is too small for a \(fmt(minW)) pt minimum plus a tile")
        }
        let r = try (0..<2).map(f.ref)
        guard log.waitFor("plan_applied", after: c, timeout: 5) != nil else {
            throw HarnessError("hyprMac never logged plan_applied for the fixture", details: log.tail())
        }
        let screen = ctx.screen.frame.insetBy(dx: -1, dy: -1)
        let usable = root.insetBy(dx: -1, dy: -1)
        try ctx.expectFrames(r, "min-size layout", timeout: 6) { m in
            guard let a = m[0].best, let b = m[1].best else { return ["a window was not measurable"] }
            var p: [String] = []
            if b.width < minW - 1 { p.append("window 1 is \(fmt(b.width)) pt wide, below its \(fmt(minW)) pt minimum") }
            for (i, x) in [a, b].enumerated() where !screen.contains(x) {
                p.append("window \(i) \(fmtRect(x)) extends beyond the screen \(fmtRect(ctx.screen.frame))")
            }
            if !usable.contains(a) { p.append("window 0 \(fmtRect(a)) is outside the usable area \(fmtRect(root))") }
            let ix = a.intersection(b)
            if !ix.isNull && ix.width > 1 && ix.height > 1 { p.append("the two windows overlap by \(fmtRect(ix))") }
            return p
        }
    }

    static let nonResizableFloats = Scenario(name: "non-resizable-floats",
                                             summary: "a non-resizable window keeps its frame; the others tile as 2") { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(3, ["--non-resizable-at", "1"])
        let r = try (0..<3).map(f.ref)
        guard let orig = f.originalFrame(1) else { throw HarnessError("fixture did not report window 1's frame") }
        let variants = ctx.oracle(2).map { [$0[0], orig, $0[1]] }
        try ctx.expect(r, variants: variants, "windows 0 and 2 tiled as 2, window 1 untouched")
    }

    // MARK: 6. sheets, panels, dialogs

    static func auxIgnored(_ kind: String) -> Scenario {
        Scenario(name: "\(kind)-ignored", summary: "a \(kind) is not tiled; the 2 windows tile as 2") { ctx in
            try ctx.startHypr()
            let f = try ctx.launchFixture(2, ["--\(kind)"])
            let r = try (0..<2).map(f.ref)
            guard let (auxID, auxFrame) = f.auxFrame(kind: kind) else {
                throw HarnessError("fixture did not report its \(kind)")
            }
            if kind == "sheet" {
                // A sheet follows its parent; it must just not take a tile.
                try ctx.expectOracle(r, "2 windows with a sheet on window 0")
                if let cg = Frames.cgWindow(auxID), !cg.onScreen {
                    throw HarnessError("the sheet is no longer on screen")
                }
            } else {
                let aux = WindowRef(pid: f.pid, id: auxID, label: kind)
                let variants = ctx.oracle(2).map { $0 + [auxFrame] }
                try ctx.expect(r + [aux], variants: variants, "2 windows tiled, \(kind) untouched")
            }
        }
    }

    // MARK: 7. tabs

    static let tabsDedupe = Scenario(name: "tabs-dedupe",
                                     summary: "a window with 3 native tabs counts as one tile") { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(2, ["--tabs", "3"])
        let tabEvents = f.events.filter { $0.json["event"] as? String == "tab" }.count
        if tabEvents != 2 { throw HarnessError("fixture created \(tabEvents) extra tabs, expected 2") }
        try ctx.expectOracle(try (0..<2).map(f.ref), "tab group + 1 window = 2 tiles")
    }

    // MARK: 8–10. ghost slots

    static let minimizeRestore = Scenario(name: "minimize-restore",
                                          summary: "minimize retiles as 2; unminimize returns to the same slot") { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(3)
        let r = try (0..<3).map(f.ref)
        let before = try ctx.expectOracle(r, "3 windows")
        var c = f.cursor
        try f.command("minimize 1")
        guard let m = f.waitFor(after: c, timeout: 5, {
            ["minimized", "minimize_failed"].contains($0["event"] as? String) && ($0["index"] as? Int) == 1 }) else {
            throw HarnessError("window 1 did not minimize")
        }
        if m.json["event"] as? String == "minimize_failed" {
            throw SkipScenario(reason: "macOS refused to minimize the fixture window"
                               + (Session.stageManagerEnabled ? " (Stage Manager is on)" : ""))
        }
        try ctx.expectOracle([r[0], r[2]], "2 windows while window 1 is minimized")
        c = f.cursor
        try f.command("unminimize 1")
        guard f.waitFor("unminimized", after: c, timeout: 5, where: { ($0["index"] as? Int) == 1 }) != nil else {
            throw HarnessError("window 1 did not unminimize")
        }
        try ctx.expect([r[1]], variants: [[before.expected[1]]], "window 1 back at its original rectangle")
        try ctx.expectOracle(r, "3 windows after unminimize")
    }

    static let hideRestore = Scenario(name: "hide-restore",
                                      summary: "hiding an app untiles its window; unhide restores it") { ctx in
        try ctx.startHypr()
        let a = try ctx.launchFixture(2, label: "A")
        let b = try ctx.launchFixture(1, label: "B")
        let r = [try a.ref(0), try a.ref(1), try b.ref(0)]
        let before = try ctx.expectOracle(r, "A0, A1, B0")
        var c = b.cursor
        try b.command("hide")
        guard b.waitFor("hidden", after: c, timeout: 5) != nil else { throw HarnessError("fixture B did not hide") }
        try ctx.expectOracle([r[0], r[1]], "A's 2 windows while B is hidden")
        c = b.cursor
        try b.command("unhide")
        guard b.waitFor("unhidden", after: c, timeout: 5) != nil else { throw HarnessError("fixture B did not unhide") }
        try ctx.expect([r[2]], variants: [[before.expected[2]]], "B0 back at its original rectangle")
        try ctx.expectOracle(r, "3 windows after unhide")
    }

    static let fullscreenRestore = Scenario(name: "fullscreen-restore",
                                            summary: "fullscreen leaves a ghost slot; exit restores 3 tiles", spaces: 1) { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(3)
        let r = try (0..<3).map(f.ref)
        try ctx.expectOracle(r, "3 windows")
        let spaceHome = ctx.spaceHome()
        defer { spaceHome.restore() }
        let home = spaceHome.space
        var c = f.cursor
        try f.command("fullscreen 1")
        guard f.waitFor("fullscreen", after: c, timeout: 10, where: {
            ($0["index"] as? Int) == 1 && $0["state"] as? String == "entered" }) != nil else {
            throw HarnessError("window 1 did not enter fullscreen")
        }
        Spaces.waitSettled()
        if let home, Spaces.activeSpace() == home { ctx.note("note: fullscreen did not switch Space") }
        try ctx.expectOracle([r[0], r[2]], "windows 0 and 2 on the original Space while 1 is fullscreen")
        c = f.cursor
        try f.command("fullscreen 1")
        guard f.waitFor("fullscreen", after: c, timeout: 10, where: {
            ($0["index"] as? Int) == 1 && $0["state"] as? String == "exited" }) != nil else {
            throw HarnessError("window 1 did not exit fullscreen")
        }
        if let home, !Spaces.waitActive(home, timeout: 5) {
            throw HarnessError("did not return to the original Space after leaving fullscreen")
        }
        try ctx.expectOracle(r, "3 windows after leaving fullscreen")
    }

    // MARK: 11–13. misbehaving apps

    static let hungAppIsolation = Scenario(name: "hung-app-isolation",
                                           summary: "a hung app delays neither another app's tiling (1 s) nor hyprMac (SIGHUP → config_loaded in 500 ms)") { ctx in
        try ctx.startHypr()
        let a = try ctx.launchFixture(1, ["--hang", "5@2"], label: "A")
        let a0 = try a.ref(0)
        try ctx.expectOracle([a0], "A alone before it hangs")
        guard a.waitFor("hang", timeout: 5) != nil else { throw HarnessError("fixture A never started hanging") }
        let b = try ctx.launchFixture(1, label: "B")
        guard let shown = b.waitFor(timeout: 1, { $0["event"] as? String == "window" })?.at else {
            throw HarnessError("fixture B reported no window")
        }
        if a.waitFor("hang_end", timeout: 0) != nil {
            throw HarnessError("inconclusive: A recovered before B's window appeared")
        }
        let b0 = try b.ref(0)
        let target = ctx.oracle(2).map { [$0[1]] }
        let left = max(0.05, 1.0 - Date().timeIntervalSince(shown))
        let res = Layout.wait([b0], variants: target, timeout: left, stable: 0)
        if !res.ok {
            throw HarnessError("B0 was not tiled within 1 s of appearing while A was hung",
                               details: res.table(title: "B0 vs its 2-window tile"))
        }
        ctx.note("B0 tiled \(String(format: "%.0f", Date().timeIntervalSince(shown) * 1000)) ms after appearing")

        // hyprMac itself must stay responsive (its menu bar and signal handling run through the
        // same coordinator): a SIGHUP must come back as config_loaded within 500 ms while A hangs.
        let h = try ctx.hypr.unwrap("hyprMac")
        let c = h.log.cursor
        let sent = Date()
        try h.reload()
        let reply = h.log.waitFor(after: c, timeout: 3) { ["config_loaded", "config_error"].contains($0.name) }
        let ms = reply.map { $0.at.timeIntervalSince(sent) * 1000 }
        if let end = a.events.last(where: { $0.json["event"] as? String == "hang_end" })?.at, end < sent {
            ctx.note("note: A had already recovered when SIGHUP was sent; responsiveness check is weaker")
        }
        guard let reply, reply.name == "config_loaded" else {
            throw HarnessError("no config_loaded within 3 s of SIGHUP while another app hung: hyprMac is blocked",
                               details: h.log.tail())
        }
        guard let ms, ms <= 500 else {
            throw HarnessError(String(format: "config_loaded took %.0f ms after SIGHUP while A hung (limit 500 ms)", ms ?? -1))
        }
        ctx.note(String(format: "SIGHUP → config_loaded in %.0f ms while A hung", ms))

        guard a.waitFor("hang_end", timeout: 8) != nil else { throw HarnessError("fixture A never recovered") }
        try ctx.expectOracle([a0, b0], "A0 and B0 after A recovers")
    }

    static let snapBackNoLoop = Scenario(name: "snap-back-no-loop",
                                         summary: "a window that snaps back does not cause a write loop") { ctx in
        try ctx.startHypr()
        let log = try ctx.log
        let c = log.cursor
        _ = try ctx.launchFixture(2, ["--snap-back"])
        guard let first = log.waitFor("plan_applied", after: c, timeout: 5) else {
            throw HarnessError("hyprMac never logged plan_applied for the fixture", details: log.tail())
        }
        let windowEnd = first.at + 3
        while Date() < windowEnd { pump(0.05); log.poll() }
        let plans = log.since(c).filter { $0.name == "plan_applied" && $0.at <= windowEnd }
        if plans.count > 5 {
            throw HarnessError("\(plans.count) plan_applied events within 3 s (limit 5): feedback loop",
                               details: plans.map(\.raw))
        }
        pump(2)
        let later = log.since(c).filter { $0.name == "plan_applied" && $0.at > windowEnd }.count
        ctx.note("\(plans.count) plan_applied in the first 3 s, \(later) in the next 2 s")
        guard ctx.hypr?.isRunning == true else { throw HarnessError("hyprMac exited") }
    }

    static let lateWindow = Scenario(name: "late-window",
                                     summary: "a window that appears 1.5 s after launch still gets tiled") { ctx in
        try ctx.startHypr()
        let f = try ctx.launchFixture(1, ["--late-window", "1.5"])
        try ctx.expectOracle([try f.ref(0)], "late window")
    }

    // MARK: 16–17. config

    static let configReload = Scenario(name: "config-reload",
                                       summary: "SIGHUP reloads gaps (inner 20, outer 0)") { ctx in
        let h = try ctx.startHypr()
        let f = try ctx.launchFixture(2)
        let r = try (0..<2).map(f.ref)
        try ctx.expectOracle(r, "2 windows, default gaps")
        let wide = Gaps(inner: 20, outer: 0)
        try h.writeConfig(HyprApp.config(wide))
        let c = h.log.cursor
        try h.reload()
        guard let ev = h.log.waitFor(after: c, timeout: 3, { ["config_loaded", "config_error"].contains($0.name) }) else {
            throw HarnessError("no config_loaded after SIGHUP (is SIGHUP handled?)", details: h.log.tail())
        }
        guard ev.name == "config_loaded", ev.double("inner") == 20, ev.double("outer") == 0 else {
            throw HarnessError("unexpected reload result: \(ev.raw)")
        }
        ctx.gaps = wide
        try ctx.expectOracle(r, gaps: wide, "2 windows, inner 20 outer 0")
    }

    static let badConfigSurvives = Scenario(name: "bad-config-survives",
                                            summary: "a syntax error on reload is reported and the old gaps stay") { ctx in
        let h = try ctx.startHypr()
        let f = try ctx.launchFixture(2)
        let r = try (0..<2).map(f.ref)
        try ctx.expectOracle(r, "2 windows, default gaps")
        try h.writeConfig("config = { gaps = { inner = 20, outer = \n")
        let c = h.log.cursor
        try h.reload()
        guard let ev = h.log.waitFor(after: c, timeout: 3, { ["config_loaded", "config_error"].contains($0.name) }) else {
            throw HarnessError("no config_error after SIGHUP with a broken config", details: h.log.tail())
        }
        guard ev.name == "config_error" else { throw HarnessError("broken config was accepted: \(ev.raw)") }
        if (ev.string("message") ?? "").isEmpty { ctx.note("config_error has an empty message") }
        pump(1)
        guard h.isRunning else { throw HarnessError("hyprMac exited after the bad config", details: h.outputTail()) }
        // A new window forces a relayout, which must still use inner 8 / outer 12.
        let ack = try f.command("open")
        guard let idx = (ack["index"] as? NSNumber)?.intValue else { throw HarnessError("open ack has no index") }
        try ctx.expectOracle(r + [try f.ref(idx)], "3 windows, still default gaps")
    }
}
