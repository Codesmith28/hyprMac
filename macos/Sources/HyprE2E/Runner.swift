import AppKit

struct Scenario {
    let name: String
    let summary: String
    /// 0: no Space requirement; 1: needs the Spaces API; 2: needs >= 2 user Spaces.
    var spaces = 0
    let body: (Context) throws -> Void
}

enum Outcome {
    case pass
    case fail(String, [String])
    case skip(String)
}

/// Per-scenario state: the hyprMac instance, fixtures, scratch dir and helpers.
final class Context {
    let name: String
    let options: Options
    let session: Session
    let workDir: URL
    let deadline: Date
    var hypr: HyprApp?
    var fixtures: [Fixture] = []
    var notes: [String] = []
    var gaps = Gaps.defaults
    private var screenCache: (frame: CGRect, visible: CGRect)?

    init(name: String, options: Options, session: Session, workDir: URL) {
        self.name = name
        self.options = options
        self.session = session
        self.workDir = workDir
        deadline = Date() + options.timeout
    }

    func checkTime() throws {
        if Date() > deadline { throw HarnessError("scenario exceeded --timeout \(fmt(options.timeout)) s") }
    }

    func remaining(_ want: Double) -> Double { max(0.5, min(want, deadline.timeIntervalSinceNow)) }

    // MARK: processes

    @discardableResult
    func startHypr(_ gaps: Gaps = .defaults) throws -> HyprApp {
        self.gaps = gaps
        let h = try HyprApp(app: options.app!, workDir: workDir, gaps: gaps)
        hypr = h
        try h.waitStarted(expect: gaps, timeout: remaining(10))
        return h
    }

    var log: EventLog {
        get throws {
            guard let h = hypr else { throw HarnessError("internal: hyprMac not started") }
            return h.log
        }
    }

    /// Launch a fixture with N windows opened one at a time, wait for ready.
    @discardableResult
    func launchFixture(_ windows: Int, _ extra: [String] = [], label: String = "A",
                       readyTimeout: Double = 15) throws -> Fixture {
        try checkTime()
        let args = ["--windows", "\(windows)", "--stagger", "\(options.stagger)",
                    "--title", "e2e \(name) \(label)"] + extra
        let f = try Fixture(executable: options.fixture!, args: args, label: label,
                            stderrTo: workDir.appendingPathComponent("fixture-\(label).err.log"))
        fixtures.append(f)
        try f.waitReady(timeout: remaining(readyTimeout))
        if screenCache == nil, let r = f.originalFrame(0) {
            screenCache = Screens.screen(containing: CGPoint(x: r.midX, y: r.midY))
        }
        return f
    }

    var screen: (frame: CGRect, visible: CGRect) {
        screenCache ?? Screens.screen(containing: nil)
    }

    func oracle(_ count: Int, _ gaps: Gaps? = nil) -> [[CGRect]] {
        Oracle.variants(count: count, usable: screen.visible, gaps: gaps ?? self.gaps)
    }

    // MARK: expectations

    /// Expect `refs` to be laid out exactly as the oracle's dwindle layout.
    @discardableResult
    func expectOracle(_ refs: [WindowRef], gaps: Gaps? = nil, _ what: String,
                      timeout: Double = 5) throws -> LayoutResult {
        try expect(refs, variants: oracle(refs.count, gaps), what, timeout: timeout)
    }

    @discardableResult
    func expect(_ refs: [WindowRef], variants: [[CGRect]], _ what: String,
                timeout: Double = 5) throws -> LayoutResult {
        try checkTime()
        let r = Layout.wait(refs, variants: variants, timeout: remaining(timeout))
        if !r.ok {
            var details = r.table(title: "\(what) — usable \(fmtRect(screen.visible)), \(gaps), ±\(fmt(Layout.tolerance)) pt")
            if let h = hypr { details += ["event log tail:"] + h.log.tail(6).map { "  " + $0 } }
            throw HarnessError("layout mismatch: \(what)", details: details)
        }
        return r
    }

    /// Wait until `check` reports no problems for frames stable 300 ms.
    @discardableResult
    func expectFrames(_ refs: [WindowRef], _ what: String, timeout: Double = 5,
                      check: ([Measurement]) -> [String]) throws -> [Measurement] {
        let deadline = Date() + remaining(timeout)
        var last: [Measurement] = []
        var since = Date()
        while true {
            let now = Frames.measure(refs)
            if now != last { last = now; since = Date() }
            let problems = check(now)
            if problems.isEmpty && Date().timeIntervalSince(since) >= 0.3 { return now }
            if Date() >= deadline {
                var details = [what] + problems
                for (ref, m) in zip(refs, now) { details.append("\(ref.label) #\(ref.id): \(fmtRect(m.best)) [\(m.source)]") }
                throw HarnessError("\(what): \(problems.first ?? "frames never settled")", details: details)
            }
            pump(0.05)
        }
    }

    func note(_ s: String) { notes.append(s) }

    // MARK: cleanup

    func cleanup() {
        let pids = Set(fixtures.map(\.pid))
        for f in fixtures { f.quit() }
        hypr?.stop()
        // Nothing of ours may be left on screen.
        let leftovers = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { pids.contains(($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1) }
        if !leftovers.isEmpty { note("warning: \(leftovers.count) fixture window(s) still listed after quit") }
        if let orig = session.originalSpace, let idx = session.originalSpaceIndex,
           Spaces.activeSpace() != orig {
            Spaces.waitSettled()
            if Spaces.activeSpace() != orig {
                note("returned to the original Space \(idx) after the scenario")
                _ = Keys.switchToSpace(idx)
            }
        }
    }
}

enum Runner {
    static func run(_ scenarios: [Scenario], options: Options, session: Session) -> Int32 {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-e2e-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let userSpaces = Spaces.userSpaces.count

        print("TAP version 13")
        print("1..\(scenarios.count)")
        print("# logs: \(base.path)")
        var passed = 0, failed = 0, skipped = 0
        var stopped = false
        let t0 = Date()

        for (i, s) in scenarios.enumerated() {
            let n = i + 1
            if stopped {
                print("ok \(n) - \(s.name) # SKIP not run: stopped after a failure (use --keep-going)")
                skipped += 1
                continue
            }
            if s.spaces >= 1 && !Spaces.available {
                print("ok \(n) - \(s.name) # SKIP the Spaces API (CGSCopyManagedDisplaySpaces) is unavailable")
                skipped += 1
                continue
            }
            if s.spaces >= 2 && userSpaces < 2 {
                print("ok \(n) - \(s.name) # SKIP needs >= 2 user Spaces, found \(userSpaces)")
                skipped += 1
                continue
            }
            let dir = base.appendingPathComponent(s.name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ctx = Context(name: s.name, options: options, session: session, workDir: dir)
            let start = Date()
            var outcome: Outcome
            do {
                try s.body(ctx)
                outcome = .pass
            } catch let e as PreflightAbort {
                ctx.cleanup()
                print("not ok \(n) - \(s.name)")
                print("Bail out! preflight: \(e.description)")
                print("#   logs: \(dir.path)")
                return 2
            } catch let e as SkipScenario {
                outcome = .skip(e.reason)
            } catch let e as HarnessError {
                outcome = .fail(e.description, e.details)
            } catch {
                outcome = .fail("\(error)", [])
            }
            ctx.cleanup()
            let secs = String(format: "%.1fs", Date().timeIntervalSince(start))
            switch outcome {
            case .pass:
                passed += 1
                print("ok \(n) - \(s.name) (\(secs))")
            case .skip(let why):
                skipped += 1
                print("ok \(n) - \(s.name) # SKIP \(why)")
            case .fail(let msg, let details):
                failed += 1
                print("not ok \(n) - \(s.name) (\(secs))")
                print("#   \(msg)")
                details.forEach { print("#     \($0)") }
                print("#   logs: \(dir.path)")
                if !options.keepGoing { stopped = true }
            }
            ctx.notes.forEach { print("#   \($0)") }
            fflush(stdout)
        }
        print(String(format: "# summary: %d passed, %d failed, %d skipped of %d (%.1fs)",
                     passed, failed, skipped, scenarios.count, Date().timeIntervalSince(t0)))
        return failed == 0 ? 0 : 1
    }
}
