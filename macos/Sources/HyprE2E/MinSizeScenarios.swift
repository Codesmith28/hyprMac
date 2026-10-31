import AppKit

/// Min-size accommodation: siblings shrink so a window that refuses its tile gets its minimum.
extension Catalog {
    static let minSizeAccommodate = Scenario(
        name: "min-size-accommodate",
        summary: "3 windows, window 2 has min 900x500: it gets it, tiles don't overlap, all inside usable") { ctx in
        let minW = 900.0, minH = 500.0
        try ctx.startHypr()
        let log = try ctx.log
        let c = log.cursor
        let f = try ctx.launchFixture(3, ["--min-size", "\(Int(minW))x\(Int(minH))@1"])
        let root = ctx.screen.visible.insetBy(dx: ctx.gaps.outer, dy: ctx.gaps.outer)
        if root.width < minW + ctx.gaps.inner + 100 || root.height < minH + ctx.gaps.inner + 100 {
            throw SkipScenario(reason: "usable area \(fmtRect(root)) is too small for a \(fmt(minW))x\(fmt(minH)) minimum plus siblings")
        }
        let r = try (0..<3).map(f.ref)
        guard log.waitFor("plan_applied", after: c, timeout: 5) != nil else {
            throw HarnessError("hyprMac never logged plan_applied for the fixture", details: log.tail())
        }
        let usable = root.insetBy(dx: -1, dy: -1)
        try ctx.expectFrames(r, "min-size-accommodate layout", timeout: 8) { m in
            var frames: [CGRect] = []
            for i in 0..<3 {
                guard let x = m[i].best else { return ["window \(i) was not measurable"] }
                frames.append(x)
            }
            var p: [String] = []
            if frames[1].width < minW - 1 || frames[1].height < minH - 1 {
                p.append("window 1 is \(fmt(frames[1].width))x\(fmt(frames[1].height)), below its \(fmt(minW))x\(fmt(minH)) minimum")
            }
            for (i, x) in frames.enumerated() where !usable.contains(x) {
                p.append("window \(i) \(fmtRect(x)) is outside the usable area \(fmtRect(root))")
            }
            for i in 0..<3 {
                for j in (i + 1)..<3 {
                    let ix = frames[i].intersection(frames[j])
                    if !ix.isNull && ix.width > 1 && ix.height > 1 {
                        p.append("windows \(i) and \(j) overlap by \(fmtRect(ix))")
                    }
                }
            }
            return p
        }
    }

    static let minSizeUnsatisfiable = Scenario(
        name: "min-size-unsatisfiable",
        summary: "two min-width-900 windows can't both fit: converges (≤ 6 plans in 3 s, none in the next 2 s), app stays responsive") { ctx in
        try ctx.startHypr()
        let log = try ctx.log
        let c = log.cursor
        _ = try ctx.launchFixture(2, ["--min-size", "900x100"])
        guard let first = log.waitFor("plan_applied", after: c, timeout: 5) else {
            throw HarnessError("hyprMac never logged plan_applied for the fixture", details: log.tail())
        }
        let windowEnd = first.at + 3
        while Date() < windowEnd { pump(0.05); log.poll() }
        let plans = log.since(c).filter { $0.name == "plan_applied" && $0.at <= windowEnd }
        // Real macOS: each min-size discovery (and the relayout it triggers) is a plan, so a handful is
        // normal (run 1: 6). What must hold is convergence: a bounded burst, then silence.
        if plans.count > 6 {
            throw HarnessError("\(plans.count) plan_applied events within 3 s (limit 6): feedback loop",
                               details: plans.map(\.raw))
        }
        pump(2)
        log.poll()
        let late = log.since(c).filter { $0.name == "plan_applied" && $0.at > windowEnd }
        if !late.isEmpty {
            throw HarnessError("\(late.count) more plan_applied events in the 2 s after the burst: not converging",
                               details: late.map(\.raw))
        }
        ctx.note("\(plans.count) plan_applied in the first 3 s, 0 in the next 2 s")
        guard ctx.hypr?.isRunning == true else { throw HarnessError("hyprMac exited") }
    }
}
