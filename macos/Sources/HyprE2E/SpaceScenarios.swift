import AppKit

// Scenarios that switch Spaces or throw windows. Every one of them restores the Space it
// started on with `defer`, so a failure never strands the user on another Desktop.

extension Catalog {
    // MARK: plain throw / ⌥N

    static let throwToSpace2 = Scenario(name: "throw-to-space-2",
                                        summary: "⌥⇧2 moves the focused window to Space 2 and both Spaces retile", spaces: 2) { ctx in
        try throwSecondWindowToSpace2(ctx) { Keys.option(2, shift: true) }
    }

    static let throwHeldModifiers = Scenario(name: "throw-held-modifiers",
                                             summary: "⌥⇧2 typed like a human (modifiers held 300 ms past key-up) still moves", spaces: 2) { ctx in
        try throwSecondWindowToSpace2(ctx) { Keys.throwHeld(2, hold: 0.3) }
    }

    /// Two windows on Space 1; focus the second; `post` the throw; expect `moved`, Space 2
    /// active, the thrown window alone on Space 2 and the other alone on Space 1.
    static func throwSecondWindowToSpace2(_ ctx: Context, post: () -> Void) throws {
        let home = ctx.spaceHome()
        defer { home.restore() }
        let spaces = try ctx.onSpace1()
        try ctx.startHypr()
        let f = try ctx.launchFixture(2)
        let r = try (0..<2).map(f.ref)
        try ctx.expectOracle(r, "2 windows on Space 1")
        try f.command("focus 1")
        pump(0.3)
        let ev = try ctx.throwAndWait(n: 2, post: post)
        guard ev.string("result") == "moved" else {
            throw HarnessError("throw reported result=\(ev.string("result") ?? "nil"); expected moved", details: [ev.raw])
        }
        guard Spaces.waitActive(spaces[1], timeout: 5) else {
            throw HarnessError("the active Space did not become Space 2 (id \(spaces[1]))")
        }
        let one = ctx.oracle(1).map { [$0[0], $0[0]] }
        try ctx.expect(r, variants: one, "both windows fill their Space (0 on Space 1, 1 on Space 2)")
        guard Keys.switchToSpace(1) else { throw HarnessError("⌥1 did not return to Space 1") }
    }

    static let missingSpaceNotice = Scenario(name: "missing-space-notice",
                                             summary: "⌥(count+1) logs missing_space", spaces: 1) { ctx in
        let count = try ctx.freeDigitSpaceCount()
        let home = ctx.spaceHome()
        defer { home.restore() }
        try ctx.startHypr()
        let log = try ctx.log
        // The fixture is frontmost so the unbound keystroke lands somewhere harmless.
        let f = try ctx.launchFixture(1)
        try f.command("focus 0")
        let before = Spaces.waitSettled()
        let c = log.cursor
        Keys.option(count + 1)
        guard let ev = log.waitFor("missing_space", after: c, timeout: 3) else {
            throw HarnessError("no missing_space event after ⌥\(count + 1)", details: log.tail())
        }
        guard ev.int("n") == count + 1, ev.int("count") == count else {
            throw HarnessError("missing_space reported n=\(ev.int("n").map(String.init) ?? "nil"), count=\(ev.int("count").map(String.init) ?? "nil"); expected n=\(count + 1), count=\(count)")
        }
        pump(0.5)
        if Spaces.activeSpace() != before { throw HarnessError("the active Space changed") }
    }

    // MARK: titlebar variants

    static let throwTitlebarVariants = Scenario(name: "throw-titlebar-variants",
                                                summary: "⌥⇧2 on transparent / tabbed / toolbar titlebars: moved or a clean noGrabPoint", spaces: 2) { ctx in
        let home = ctx.spaceHome()
        defer { home.restore() }
        let spaces = try ctx.onSpace1()
        try ctx.startHypr()
        var record: [String] = []
        for variant in ["transparent", "tabs", "toolbar"] {
            let f = try ctx.launchFixture(1, ["--titlebar", variant], label: variant)
            let w = try f.ref(0)
            let alone = try ctx.expectOracle([w], "\(variant): window alone on Space 1")
            let hits = GrabProbe.hits(window: w.id, frame: alone.actual[0].best ?? .zero)
            try f.command("focus 0")
            pump(0.3)
            let ev = try ctx.throwAndWait(n: 2) { Keys.option(2, shift: true) }
            let result = ev.string("result") ?? "nil"
            record.append("\(variant): \(result) [titlebar hits: \(hits.map(\.description).joined(separator: ", "))]")
            switch result {
            case "moved":
                guard Spaces.waitActive(spaces[1], timeout: 5) else {
                    throw HarnessError("\(variant): result moved but Space 2 never became active", details: record)
                }
                try ctx.expect([w], variants: ctx.oracle(1), "\(variant): thrown window fills Space 2")
                guard Keys.switchToSpace(1) else { throw HarnessError("⌥1 did not return to Space 1", details: record) }
            case "noGrabPoint":
                // A clean refusal: nothing moved, no Space switch, a notification for the user.
                Spaces.waitSettled()
                guard Spaces.activeSpace() == spaces[0] else {
                    throw HarnessError("\(variant): noGrabPoint but the Space changed", details: record)
                }
                try ctx.expect([w], variants: ctx.oracle(1), "\(variant): window untouched after noGrabPoint")
            default:
                throw HarnessError("\(variant): throw result \(result); expected moved or noGrabPoint", details: record + [ev.raw])
            }
            f.quit()
        }
        record.forEach { ctx.note($0) }
    }

    // MARK: edge results

    static let throwNoSpace = Scenario(name: "throw-no-space",
                                       summary: "⌥⇧(count+1) reports noSuchSpace and a missing_space notice", spaces: 1) { ctx in
        let count = try ctx.freeDigitSpaceCount()
        let home = ctx.spaceHome()
        defer { home.restore() }
        try ctx.startHypr()
        let log = try ctx.log
        let f = try ctx.launchFixture(1)
        let w = try f.ref(0)
        try ctx.expectOracle([w], "1 window")
        try f.command("focus 0")
        pump(0.3)
        let before = Spaces.waitSettled()
        let c = log.cursor
        let ev = try ctx.throwAndWait(n: count + 1) { Keys.option(count + 1, shift: true) }
        guard ev.string("result") == "noSuchSpace" else {
            throw HarnessError("throw reported \(ev.string("result") ?? "nil"); expected noSuchSpace", details: [ev.raw])
        }
        guard let notice = log.waitFor("missing_space", after: c, timeout: 2) else {
            throw HarnessError("throw reported noSuchSpace but no missing_space event was logged "
                               + "(the notice must be observable, not only posted to Notification Center)",
                               details: log.tail())
        }
        guard notice.int("n") == count + 1, notice.int("count") == count else {
            throw HarnessError("missing_space reported \(notice.raw); expected n=\(count + 1), count=\(count)")
        }
        pump(0.3)
        guard Spaces.activeSpace() == before else { throw HarnessError("the active Space changed") }
        try ctx.expectOracle([w], "window untouched")
    }

    static let throwAlreadyThere = Scenario(name: "throw-already-there",
                                            summary: "⌥⇧(current Space) reports alreadyThere and changes nothing", spaces: 1) { ctx in
        let home = ctx.spaceHome()
        defer { home.restore() }
        guard let current = Spaces.waitSettled(), let n = Spaces.index(of: current), n <= 9 else {
            throw SkipScenario(reason: "the current Space is not one of user Spaces 1–9")
        }
        try ctx.startHypr()
        let f = try ctx.launchFixture(1)
        let w = try f.ref(0)
        try ctx.expectOracle([w], "1 window")
        try f.command("focus 0")
        pump(0.3)
        let ev = try ctx.throwAndWait(n: n) { Keys.option(n, shift: true) }
        guard ev.string("result") == "alreadyThere" else {
            throw HarnessError("throw reported \(ev.string("result") ?? "nil"); expected alreadyThere", details: [ev.raw])
        }
        pump(0.3)
        guard Spaces.activeSpace() == current else { throw HarnessError("the active Space changed") }
        try ctx.expectOracle([w], "window untouched")
    }

    static let throwRapid = Scenario(name: "throw-rapid",
                                     summary: "two throws 150 ms apart: the second is retried or reported, never lost; cursor restored", spaces: 2) { ctx in
        let home = ctx.spaceHome()
        defer { home.restore() }
        let spaces = try ctx.onSpace1()
        let second = spaces.count >= 3 ? 3 : 1
        try ctx.startHypr()
        let log = try ctx.log
        let f = try ctx.launchFixture(2)
        let r = try (0..<2).map(f.ref)
        try ctx.expectOracle(r, "2 windows on Space 1")
        try f.command("focus 1")
        pump(0.3)
        Spaces.waitSettled()
        let cursorBefore = Keys.cursor
        let c = log.cursor
        let t0 = Date()
        Keys.option(2, shift: true)
        pump(max(0, 0.15 - Date().timeIntervalSince(t0)))
        Keys.option(second, shift: true)
        let gap = Date().timeIntervalSince(t0)

        // Collect throw events until both presses are accounted for (retries may add more).
        let deadline = Date() + 10
        var events: [EventLog.Event] = []
        while Date() < deadline {
            events = log.since(c).filter { $0.name == "throw" }
            if events.contains(where: { $0.int("n") == second }) { break }
            pump(0.1)
        }
        let summary = events.map { "n=\($0.int("n") ?? -1) \($0.string("result") ?? "?")" }
        ctx.note(String(format: "presses %.0f ms apart; throw events: ", gap * 1000) + summary.joined(separator: ", "))
        guard let first = events.first(where: { $0.int("n") == 2 }) else {
            throw HarnessError("no throw event for the first press (⌥⇧2)", details: log.tail())
        }
        guard first.string("result") == "moved" else {
            throw HarnessError("first throw reported \(first.string("result") ?? "nil"); expected moved", details: summary)
        }
        guard let last = events.last(where: { $0.int("n") == second }) else {
            throw HarnessError("the second press (⌥⇧\(second)) was lost silently: no throw event within 10 s",
                               details: summary + log.tail(4))
        }
        let allowed = ["moved", "alreadyThere", "transitionInFlight"]
        guard allowed.contains(last.string("result") ?? "") else {
            throw HarnessError("second throw reported \(last.string("result") ?? "nil"); expected one of \(allowed)", details: summary)
        }
        Spaces.waitSettled()
        pump(0.3)
        let cursorAfter = Keys.cursor
        guard abs(cursorAfter.x - cursorBefore.x) <= 1, abs(cursorAfter.y - cursorBefore.y) <= 1 else {
            throw HarnessError("cursor ended at \(cursorAfter), started at \(cursorBefore)", details: summary)
        }
    }

    // MARK: displays

    static let displayCache = Scenario(name: "display-cache",
                                       summary: "per-display Space ids with several displays (manual)") { _ in
        let n = NSScreen.screens.count
        if n < 2 {
            throw SkipScenario(reason: "single display: per-display Space ids need 2+ displays")
        }
        throw SkipScenario(reason: "\(n) displays: verify by hand with \"Displays have separate Spaces\" off (not automated)")
    }
}

extension Context {
    /// Make user Space 1 active (waiting out any transition first) and return the user Spaces.
    @discardableResult
    func onSpace1() throws -> [UInt64] {
        let spaces = Spaces.userSpaces
        guard !spaces.isEmpty else { throw SkipScenario(reason: "could not read the user Spaces") }
        if Spaces.waitSettled() != spaces[0] {
            guard Keys.switchToSpace(1) else { throw HarnessError("could not switch to Space 1 before the test") }
        }
        return spaces
    }

    /// The user Space count, when ⌥(count+1) is still a digit key (count < 9).
    func freeDigitSpaceCount() throws -> Int {
        let count = Spaces.userSpaces.count
        guard count >= 1 else { throw SkipScenario(reason: "could not read the user Space count") }
        guard count < 9 else { throw SkipScenario(reason: "\(count) user Spaces: no free ⌥N to test") }
        return count
    }

    /// Wait out any Space transition, `post` a throw, return its `throw` event for Space `n`.
    func throwAndWait(n: Int, timeout: Double = 6, post: () -> Void) throws -> EventLog.Event {
        let log = try self.log
        Spaces.waitSettled()
        let c = log.cursor
        post()
        guard let ev = log.waitFor("throw", after: c, timeout: remaining(timeout), where: { $0.int("n") == n }) else {
            throw HarnessError("no throw event for Space \(n) within \(fmt(timeout)) s", details: log.tail())
        }
        return ev
    }
}

extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let v = self else { throw HarnessError("internal: \(what) missing") }
        return v
    }
}
