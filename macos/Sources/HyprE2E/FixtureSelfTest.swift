import AppKit

/// `--fixture-selftest`: launch the fixture, check its event stream and its
/// windows (AX when trusted, otherwise CGWindowList only), quit it. Needs no
/// hyprMac and posts no input events.
enum FixtureSelfTest {
    static func run(fixture: URL) -> Int32 {
        var n = 0, failures = 0
        func check(_ ok: Bool, _ name: String, _ details: [String] = []) {
            n += 1
            print("\(ok ? "ok" : "not ok") \(n) - \(name)")
            if !ok { failures += 1; details.forEach { print("#   \($0)") } }
        }
        func skip(_ name: String, _ why: String) { n += 1; print("ok \(n) - \(name) # SKIP \(why)") }

        let front = NSWorkspace.shared.frontmostApplication
        let trusted = AXIsProcessTrusted()
        print("TAP version 13")
        print("# fixture: \(fixture.path)")
        print("# AX trusted: \(trusted)")

        let f: Fixture
        do {
            f = try Fixture(executable: fixture, args: ["--windows", "2", "--stagger", "100", "--tabs", "2",
                                                        "--title", "e2e selftest"],
                            label: "S", stderrTo: nil)
        } catch {
            print("not ok 1 - fixture launches\n#   \(error)\n1..1")
            return 1
        }
        defer {
            f.quit()
            front?.activate(options: NSApplication.ActivationOptions(rawValue: 1 << 1))
        }

        let ready = try? f.waitReady(timeout: 10)
        check(ready != nil, "fixture reports ready")
        let w0 = f.windowNumber(0), w1 = f.windowNumber(1)
        check(w0 != nil && w1 != nil && w0 != w1, "window events carry distinct windowNumbers",
              ["window 0: \(w0.map(String.init) ?? "nil"), window 1: \(w1.map(String.init) ?? "nil")"])
        let pidOK = f.events.filter { $0.json["event"] as? String == "window" }
            .allSatisfy { ($0.json["pid"] as? NSNumber)?.int32Value == f.pid }
        check(pidOK, "window events carry the fixture pid")
        check(f.events.contains { $0.json["event"] as? String == "tab" }, "--tabs 2 reports a tab")
        check(((ready?["screen"] as? [String: Any])?["visible"]).flatMap(rectFromArray) != nil,
              "ready reports the screen's usable rect")

        guard let w0, let w1, ready != nil else { return finish(n, failures) }
        let refs = [WindowRef(pid: f.pid, id: w0, label: "S0"), WindowRef(pid: f.pid, id: w1, label: "S1")]
        let m = Layout.settle(refs, timeout: 3)
        let originals = [f.originalFrame(0), f.originalFrame(1)]
        for i in 0..<2 {
            let cgOK = m[i].cg.flatMap { cg in originals[i].map { Oracle.close(cg, $0) } } ?? false
            check(cgOK && m[i].onScreen, "CGWindowList shows window \(i) on screen at its reported frame",
                  ["reported \(fmtRect(originals[i])), CGWindowList \(fmtRect(m[i].cg)), on screen \(m[i].onScreen)"])
        }
        if trusted {
            for i in 0..<2 {
                let ok = m[i].ax.flatMap { ax in originals[i].map { Oracle.close(ax, $0) } } ?? false
                check(ok, "AX window \(i) found via _AXUIElementGetWindow at its reported frame",
                      ["reported \(fmtRect(originals[i])), AX \(fmtRect(m[i].ax))"])
            }
        } else {
            skip("AX frames", "harness is not AX-trusted; CGWindowList only")
            skip("AX frames (2)", "harness is not AX-trusted")
        }

        let ack = try? f.command("open")
        let idx = (ack?["index"] as? NSNumber)?.intValue
        check(idx == 2 && f.windowNumber(2) != nil, "open → ack with index 2 and a window event")

        var c = f.cursor
        let closed = (try? f.command("close 0")) != nil
            && f.waitFor("closed", after: c, timeout: 2, where: { ($0["index"] as? Int) == 0 }) != nil
        pump(0.3)
        check(closed && !(Frames.cgWindow(w0)?.onScreen ?? false), "close 0 → closed event, window gone")

        c = f.cursor
        f.send("bogus 1")
        let bad = f.waitFor("ack", after: c, timeout: 2, where: { $0["line"] as? String == "bogus 1" })
        check(bad?["ok"] as? Bool == false, "unknown command → ack with ok false")

        let c2 = f.cursor
        f.send("frames")
        let frames = f.waitFor("ack", after: c2, timeout: 2, where: { $0["cmd"] as? String == "frames" })
        check((frames?["frames"] as? [String: Any])?.count == 2, "frames → 2 open windows")

        f.send("quit")
        let deadline = Date() + 3
        while f.process.isRunning && Date() < deadline { pump(0.05) }
        check(!f.process.isRunning, "quit → process exits within 3 s")
        let left = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == f.pid }
        check(left.isEmpty, "no fixture windows remain", ["\(left.count) window(s) still listed"])

        // stdin EOF must also quit it.
        if let g = try? Fixture(executable: fixture, args: ["--windows", "1"], label: "E", stderrTo: nil) {
            _ = try? g.waitReady(timeout: 10)
            g.quit()   // closes stdin after "quit"; verify the EOF path separately below
            check(!g.process.isRunning, "fixture exits after quit + stdin EOF")
        }
        if let h = try? Fixture(executable: fixture, args: ["--windows", "1"], label: "F", stderrTo: nil) {
            _ = try? h.waitReady(timeout: 10)
            h.closeStdin()
            let dl = Date() + 3
            while h.process.isRunning && Date() < dl { pump(0.05) }
            check(!h.process.isRunning, "fixture exits on stdin EOF alone")
            h.quit()
        }
        return finish(n, failures)
    }

    private static func finish(_ n: Int, _ failures: Int) -> Int32 {
        print("1..\(n)")
        print("# summary: \(n - failures) passed, \(failures) failed (fixture self-test)")
        return failures == 0 ? 0 : 1
    }
}
