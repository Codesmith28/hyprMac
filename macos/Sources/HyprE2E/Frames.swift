import AppKit
import ApplicationServices

/// A window under test: owner pid + CGWindowID (== NSWindow.windowNumber).
struct WindowRef: Hashable {
    let pid: pid_t
    let id: CGWindowID
    let label: String
}

struct Measurement: Equatable {
    var ax: CGRect?
    var cg: CGRect?
    var onScreen = false
    /// AX when available (what hyprMac writes), CGWindowList otherwise
    /// (windows on other Spaces, untrusted runs, hung apps).
    var best: CGRect? { ax ?? cg }
    var source: String { ax != nil ? "ax" : (cg != nil ? "cg" : "—") }
}

enum Frames {
    static var axTrusted: Bool { AXIsProcessTrusted() }

    /// AX windows of `pid` keyed by CGWindowID.
    static func axWindows(pid: pid_t) -> [CGWindowID: AXUIElement] {
        guard axTrusted, Private.axGetWindow != nil else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)   // a hung app must not stall the harness
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [:] }
        var out: [CGWindowID: AXUIElement] = [:]
        for w in list {
            AXUIElementSetMessagingTimeout(w, 0.5)
            if let id = Private.windowID(of: w) { out[id] = w }
        }
        return out
    }

    static func axFrame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func cgWindow(_ id: CGWindowID) -> (bounds: CGRect, onScreen: Bool, info: [String: Any])? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = list.first, let b = d[kCGWindowBounds as String],
              let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { return nil }
        return (r, (d[kCGWindowIsOnscreen as String] as? Bool) ?? false, d)
    }

    static func measure(_ refs: [WindowRef]) -> [Measurement] {
        var axByPid: [pid_t: [CGWindowID: AXUIElement]] = [:]
        return refs.map { ref in
            if axByPid[ref.pid] == nil { axByPid[ref.pid] = axWindows(pid: ref.pid) }
            var m = Measurement()
            if let el = axByPid[ref.pid]?[ref.id] { m.ax = axFrame(el) }
            if let cg = cgWindow(ref.id) { m.cg = cg.bounds; m.onScreen = cg.onScreen }
            return m
        }
    }

    static func isIgnored(pid: pid_t, bundleIDs: Set<String>) -> Bool {
        guard !bundleIDs.isEmpty, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return bundleIDs.contains(id)
    }

    /// Normal (layer 0) on-screen windows that do not belong to `excluding`, nor to an app hyprMac was
    /// told to ignore (`rules.ignore`: the terminal running the tests): those are never tiled or moved,
    /// so they are not part of any layout.
    static func foreignWindows(excluding pids: Set<pid_t>) -> [(owner: String, title: String)] {
        let ignored = Set(HyprApp.ignoredBundleIDs)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, !pids.contains(pid),
                  !isIgnored(pid: pid, bundleIDs: ignored),
                  let b = d[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: b as! CFDictionary), r.width > 40, r.height > 40
            else { return nil }
            return (d[kCGWindowOwnerName as String] as? String ?? "?", d[kCGWindowName as String] as? String ?? "")
        }
    }
}

// MARK: - waiting for a layout

struct LayoutResult {
    let ok: Bool
    let refs: [WindowRef]
    let actual: [Measurement]
    let expected: [CGRect]      // closest variant
    let crossCheck: [String]

    func table(title: String) -> [String] {
        var lines = [title,
                     "window".padding(toLength: 16, withPad: " ", startingAt: 0)
                        + "expected".padding(toLength: 30, withPad: " ", startingAt: 0)
                        + "actual".padding(toLength: 30, withPad: " ", startingAt: 0) + "src  Δmax"]
        for (i, ref) in refs.enumerated() {
            let e = i < expected.count ? expected[i] : nil
            let a = actual[i].best
            let d = (e != nil && a != nil) ? fmt(Oracle.maxDelta(e!, a!)) : "—"
            lines.append("\(ref.label) #\(ref.id)".padding(toLength: 16, withPad: " ", startingAt: 0)
                         + fmtRect(e).padding(toLength: 30, withPad: " ", startingAt: 0)
                         + fmtRect(a).padding(toLength: 30, withPad: " ", startingAt: 0)
                         + actual[i].source.padding(toLength: 5, withPad: " ", startingAt: 0) + d)
        }
        return lines + crossCheck
    }
}

enum Layout {
    static let tolerance = 1.0

    static func matches(_ actual: [Measurement], _ expected: [CGRect]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { m, e in
            m.best.map { Oracle.close($0, e, tolerance: tolerance) } ?? false
        }
    }

    /// Poll until the frames match one of `variants` and have been unchanged
    /// for `stable` seconds, or `timeout` passes.
    static func wait(_ refs: [WindowRef], variants: [[CGRect]], timeout: Double = 5,
                     stable: Double = 0.3) -> LayoutResult {
        let deadline = Date() + timeout
        var last: [Measurement] = []
        var since = Date()
        while true {
            let now = Frames.measure(refs)
            if now != last { last = now; since = Date() }
            let hit = variants.firstIndex { matches(now, $0) }
            if let hit, Date().timeIntervalSince(since) >= stable {
                return LayoutResult(ok: true, refs: refs, actual: now, expected: variants[hit], crossCheck: [])
            }
            if Date() >= deadline {
                let closest = variants.min { score(now, $0) < score(now, $1) } ?? []
                return LayoutResult(ok: false, refs: refs, actual: now, expected: closest,
                                    crossCheck: crossCheck(refs, now))
            }
            pump(0.05)
        }
    }

    /// Wait until frames stop changing (no expectation).
    static func settle(_ refs: [WindowRef], timeout: Double = 5, stable: Double = 0.3) -> [Measurement] {
        let deadline = Date() + timeout
        var last = Frames.measure(refs)
        var since = Date()
        while Date() < deadline {
            pump(0.05)
            let now = Frames.measure(refs)
            if now != last { last = now; since = Date() }
            if Date().timeIntervalSince(since) >= stable { break }
        }
        return last
    }

    private static func score(_ a: [Measurement], _ e: [CGRect]) -> Double {
        zip(a, e).reduce(0) { acc, p in acc + (p.0.best.map { Oracle.maxDelta($0, p.1) } ?? 1e6) }
    }

    private static func crossCheck(_ refs: [WindowRef], _ m: [Measurement]) -> [String] {
        zip(refs, m).compactMap { ref, m in
            if let ax = m.ax, let cg = m.cg, Oracle.maxDelta(ax, cg) > tolerance {
                return "note: \(ref.label) AX \(fmtRect(ax)) disagrees with CGWindowList \(fmtRect(cg))"
            }
            if m.ax == nil && m.cg == nil { return "note: \(ref.label) not found via AX or CGWindowList" }
            return nil
        }
    }
}
