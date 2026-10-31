import AppKit

/// Every child we spawn, so an interrupted run never leaves a tiler or a
/// fixture behind.
enum Children {
    private static let lock = NSLock()
    private static var procs: [Int32: Process] = [:]

    static func add(_ p: Process) { lock.lock(); procs[p.processIdentifier] = p; lock.unlock() }
    static func remove(_ p: Process) { lock.lock(); procs[p.processIdentifier] = nil; lock.unlock() }

    static func killAll() {
        lock.lock(); let all = Array(procs.values); procs.removeAll(); lock.unlock()
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

/// Stop a process: optional polite step, SIGTERM, then SIGKILL.
func stopProcess(_ p: Process, grace: Double = 3) {
    guard p.isRunning else { Children.remove(p); return }
    p.terminate()
    let deadline = Date() + grace
    while p.isRunning && Date() < deadline { pump(0.05) }
    if p.isRunning { kill(p.processIdentifier, SIGKILL); pump(0.1) }
    Children.remove(p)
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    var details: [String] = []
    init(_ d: String, details: [String] = []) { description = d; self.details = details }
}

struct SkipScenario: Error { let reason: String }

/// Abort the whole run with exit status 2 (environment cannot be tested).
struct PreflightAbort: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - fixture

/// A running `hyprmac-fixture` driven over stdin/stdout.
final class Fixture {
    let label: String
    let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var _events: [(at: Date, json: [String: Any])] = []
    private(set) var readyInfo: [String: Any]?

    var pid: pid_t { process.processIdentifier }

    init(executable: URL, args: [String], label: String, stderrTo: URL?) throws {
        self.label = label
        process.executableURL = executable
        process.arguments = args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        if let stderrTo {
            FileManager.default.createFile(atPath: stderrTo.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: stderrTo)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.ingest(d)
        }
        do { try process.run() } catch {
            throw HarnessError("cannot launch fixture \(executable.path): \(error)")
        }
        Children.add(process)
    }

    private func ingest(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if d.isEmpty { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                _events.append((Date(), obj))
            }
        }
    }

    var events: [(at: Date, json: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _events }
    var cursor: Int { events.count }

    func waitFor(after cursor: Int = 0, timeout: Double,
                 _ predicate: ([String: Any]) -> Bool) -> (at: Date, json: [String: Any])? {
        let deadline = Date() + timeout
        repeat {
            let evs = events
            if cursor < evs.count, let hit = evs[cursor...].first(where: { predicate($0.json) }) { return hit }
            if Date() >= deadline || !process.isRunning && cursor >= events.count { return nil }
            pump(0.02)
        } while true
    }

    func waitFor(_ event: String, after cursor: Int = 0, timeout: Double,
                 where pred: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        waitFor(after: cursor, timeout: timeout) { $0["event"] as? String == event && pred($0) }?.json
    }

    /// Wait for `{"event":"ready"}`.
    @discardableResult
    func waitReady(timeout: Double = 10) throws -> [String: Any] {
        guard let r = waitFor("ready", timeout: timeout) else {
            throw HarnessError("fixture \(label) did not report ready within \(fmt(timeout)) s"
                               + (process.isRunning ? "" : " (exited with \(process.terminationStatus))"))
        }
        readyInfo = r
        return r
    }

    /// Window number of the window with command index `i`.
    func windowNumber(_ i: Int) -> CGWindowID? {
        events.last { $0.json["event"] as? String == "window" && ($0.json["index"] as? NSNumber)?.intValue == i }
            .flatMap { ($0.json["windowNumber"] as? NSNumber)?.uint32Value }
    }

    /// Frame (top-left points) the fixture created window `i` with.
    func originalFrame(_ i: Int) -> CGRect? {
        events.last { $0.json["event"] as? String == "window" && ($0.json["index"] as? NSNumber)?.intValue == i }
            .flatMap { rectFromArray($0.json["frame"]) }
    }

    func auxFrame(kind: String) -> (CGWindowID, CGRect)? {
        guard let e = events.last(where: { $0.json["event"] as? String == "aux" && $0.json["kind"] as? String == kind }),
              let n = (e.json["windowNumber"] as? NSNumber)?.uint32Value,
              let f = rectFromArray(e.json["frame"]) else { return nil }
        return (n, f)
    }

    func ref(_ i: Int) throws -> WindowRef {
        guard let n = windowNumber(i) else { throw HarnessError("fixture \(label) never reported window \(i)") }
        return WindowRef(pid: pid, id: n, label: "\(label)\(i)")
    }

    func send(_ line: String) {
        guard process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Send a command and wait for its ack; throws when it is refused.
    @discardableResult
    func command(_ line: String, timeout: Double = 5) throws -> [String: Any] {
        let c = cursor
        send(line)
        guard let ack = waitFor("ack", after: c, timeout: timeout, where: { $0["line"] as? String == line }) else {
            throw HarnessError("fixture \(label) did not ack '\(line)' within \(fmt(timeout)) s")
        }
        if ack["ok"] as? Bool == false {
            throw HarnessError("fixture \(label) refused '\(line)': \(ack["error"] ?? "?")")
        }
        return ack
    }

    func closeStdin() { try? stdinPipe.fileHandleForWriting.close() }

    /// Quit politely (command, then stdin EOF), escalate if needed.
    func quit() {
        if process.isRunning {
            send("quit")
            try? stdinPipe.fileHandleForWriting.close()
            let deadline = Date() + 3
            while process.isRunning && Date() < deadline { pump(0.05) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stopProcess(process, grace: 1)
    }
}

func rectFromArray(_ any: Any?) -> CGRect? {
    guard let a = any as? [NSNumber], a.count == 4 else { return nil }
    return CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue)
}

// MARK: - hyprMac

/// The app under test, launched as
/// `<app>/Contents/MacOS/hyprMac --config <tmp> --event-log <tmp>`.
final class HyprApp {
    let process = Process()
    let configURL: URL
    let log: EventLog
    let outputURL: URL

    init(app: URL, workDir: URL, gaps: Gaps) throws {
        let exe = app.appendingPathComponent("Contents/MacOS/hyprMac")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw HarnessError("no executable at \(exe.path) (run `make app`)")
        }
        configURL = workDir.appendingPathComponent("config.lua")
        let logURL = workDir.appendingPathComponent("events.jsonl")
        outputURL = workDir.appendingPathComponent("hyprmac.out.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        log = EventLog(url: logURL)
        try HyprApp.writeConfig(HyprApp.config(gaps), to: configURL)

        process.executableURL = exe
        process.arguments = ["--config", configURL.path, "--event-log", logURL.path]
        let out = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw HarnessError("cannot launch \(exe.path): \(error)") }
        Children.add(process)
    }

    static func config(_ g: Gaps) -> String {
        "config = { gaps = { inner = \(fmt(g.inner)), outer = \(fmt(g.outer)) } }\n"
    }

    static func writeConfig(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func writeConfig(_ text: String) throws { try HyprApp.writeConfig(text, to: configURL) }

    var isRunning: Bool { process.isRunning }

    func reload() throws {
        guard process.isRunning else { throw HarnessError("hyprMac is not running; cannot send SIGHUP") }
        kill(process.processIdentifier, SIGHUP)
    }

    /// Wait for `started` and `config_loaded`; turn every way this can go
    /// wrong into a message that says what part of the contract is missing.
    func waitStarted(expect gaps: Gaps, timeout: Double = 10) throws {
        let dead = { [process] in !process.isRunning }
        guard log.waitFor(after: 0, timeout: timeout, abortIf: dead, { $0.name == "started" }) != nil else {
            let why = process.isRunning
                ? "hyprMac wrote no {\"event\":\"started\"} to \(log.url.path) within \(fmt(timeout)) s; is --event-log implemented?"
                : "hyprMac exited with status \(process.terminationStatus) before writing {\"event\":\"started\"} to \(log.url.path)"
            pump(0.1)   // let its last stderr lines land
            throw HarnessError(why, details: outputTail())
        }
        // The app logs config_loaded/config_error and then, synchronously in
        // the same start-up step, paused when it refuses to tile.
        let got = log.waitFor(after: 0, timeout: 5, abortIf: dead) {
            ["config_loaded", "config_error", "paused"].contains($0.name)
        }
        guard let got else {
            throw HarnessError("hyprMac started but reported neither config_loaded nor config_error within 5 s"
                               + " (is --config implemented?)", details: log.tail())
        }
        let paused = got.name == "paused" ? got
            : log.waitFor(after: got.seq + 1, timeout: HyprApp.pauseGrace, abortIf: dead, { $0.name == "paused" })
        if let paused { throw HyprApp.pausedAtStartup(paused.string("reason") ?? "?") }
        switch got.name {
        case "config_error":
            throw HarnessError("hyprMac rejected the harness config: \(got.string("message") ?? "?")")
        default:
            let inner = got.double("inner"), outer = got.double("outer")
            if inner != gaps.inner || outer != gaps.outer {
                throw HarnessError("config_loaded reported inner \(inner.map(fmt) ?? "nil"), outer \(outer.map(fmt) ?? "nil");"
                                   + " expected \(gaps)")
            }
        }
    }

    /// How long after the config result a startup `paused` still counts.
    static let pauseGrace = 0.75

    /// `paused` right after start means the run cannot work at all.
    static func pausedAtStartup(_ reason: String) -> PreflightAbort {
        switch reason {
        case "stage_manager":
            return PreflightAbort("hyprMac paused at startup because Stage Manager is on: "
                                  + "run make install first or turn off Stage Manager, then re-run")
        case "accessibility":
            return PreflightAbort("hyprMac paused at startup: it is not Accessibility-trusted. "
                                  + "Grant \(Session.terminalName) Accessibility (it passes to child processes), "
                                  + "or run make install, then re-run")
        default:
            return PreflightAbort("hyprMac paused at startup (reason: \(reason)); it will not tile, so nothing can be tested")
        }
    }

    func outputTail(_ n: Int = 10) -> [String] {
        guard let s = try? String(contentsOf: outputURL, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").suffix(n).map { "hyprMac: \($0)" }
    }

    func stop() { stopProcess(process) }
}
