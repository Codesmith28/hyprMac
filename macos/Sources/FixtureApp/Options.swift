import Foundation

/// Command-line options of `hyprmac-fixture`. All flags are combinable.
struct FixtureOptions {
    var windows = 1
    var title = "fixture"
    /// Content minimum size; applies to every window unless `minSizeIndex` is set.
    var minSize: CGSize? = nil
    var minSizeIndex: Int? = nil
    /// `--non-resizable` (all windows) or `--non-resizable-at I` (repeatable).
    var nonResizableAll = false
    var nonResizableIndices: Set<Int> = []
    /// Total number of tabs in the first window's tab group (N >= 2 adds N-1 tabs).
    var tabs = 0
    var sheet = false
    var panel = false
    var dialog = false
    var snapBack = false
    var slowResizeMS = 0
    var lateWindow: Double = 0
    var hang: (seconds: Double, after: Double)? = nil
    var fullscreenAfter: Double? = nil
    /// Delay between initial windows (ms) so a tiler sees them one at a time.
    var staggerMS = 0
    var windowSize = CGSize(width: 480, height: 320)

    static let usage = """
    usage: hyprmac-fixture [options]
      --windows N              initial windows (default 1)
      --title PREFIX           window title prefix (default "fixture")
      --min-size WxH[@I]       contentMinSize (all windows, or only window I)
      --non-resizable          every window is non-resizable
      --non-resizable-at I     window I is non-resizable (repeatable)
      --tabs N                 first window becomes a native tab group of N tabs
      --sheet                  attach a sheet to the first window
      --panel                  open a floating NSPanel utility window
      --dialog                 open a dialog-styled NSWindow (AXDialog subrole)
      --snap-back              200 ms after any resize, reset to the original size
      --slow-resize MS         apply external frame changes only after MS (debounced)
      --late-window SECONDS    open the first window only after a delay
      --hang SECONDS@AFTER     block the main thread SECONDS long, AFTER s after launch
      --fullscreen-after S     toggle native fullscreen on window 0 after S seconds
      --stagger MS             delay between initial windows (default 0)
      --size WxH               initial content size (default 480x320)

    stdin commands: open | close I | minimize I | unminimize I | fullscreen I |
                    hide | unhide | focus I | frames | quit       (EOF quits)
    stdout: one JSON object per line ({"event":"window"|"ready"|"ack"|...})
    """

    static func parse(_ args: [String]) throws -> FixtureOptions {
        var o = FixtureOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw OptionError("\(flag) needs a value") }
            return args[i]
        }
        func int(_ flag: String) throws -> Int {
            let v = try value(flag)
            guard let n = Int(v), n >= 0 else { throw OptionError("\(flag): bad integer '\(v)'") }
            return n
        }
        func double(_ flag: String, _ s: String) throws -> Double {
            guard let d = Double(s), d >= 0, d.isFinite else { throw OptionError("\(flag): bad number '\(s)'") }
            return d
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--windows": o.windows = try int(a)
            case "--title": o.title = try value(a)
            case "--min-size":
                let v = try value(a)
                let parts = v.split(separator: "@", maxSplits: 1).map(String.init)
                o.minSize = try parseSize(a, parts[0])
                if parts.count == 2 {
                    guard let idx = Int(parts[1]), idx >= 0 else { throw OptionError("\(a): bad index in '\(v)'") }
                    o.minSizeIndex = idx
                }
            case "--non-resizable": o.nonResizableAll = true
            case "--non-resizable-at": o.nonResizableIndices.insert(try int(a))
            case "--tabs": o.tabs = try int(a)
            case "--sheet": o.sheet = true
            case "--panel": o.panel = true
            case "--dialog": o.dialog = true
            case "--snap-back": o.snapBack = true
            case "--slow-resize": o.slowResizeMS = try int(a)
            case "--late-window": o.lateWindow = try double(a, try value(a))
            case "--hang":
                let v = try value(a)
                let parts = v.split(separator: "@").map(String.init)
                guard parts.count == 2 else { throw OptionError("\(a) expects SECONDS@AFTER, got '\(v)'") }
                o.hang = (try double(a, parts[0]), try double(a, parts[1]))
            case "--fullscreen-after": o.fullscreenAfter = try double(a, try value(a))
            case "--stagger": o.staggerMS = try int(a)
            case "--size": o.windowSize = try parseSize(a, try value(a))
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw OptionError("unknown option '\(a)'")
            }
            i += 1
        }
        return o
    }

    func isResizable(_ index: Int) -> Bool {
        !(nonResizableAll || nonResizableIndices.contains(index))
    }

    func minSize(for index: Int) -> CGSize? {
        guard let s = minSize else { return nil }
        if let only = minSizeIndex { return only == index ? s : nil }
        return s
    }
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private func parseSize(_ flag: String, _ s: String) throws -> CGSize {
    let p = s.lowercased().split(separator: "x").map(String.init)
    guard p.count == 2, let w = Double(p[0]), let h = Double(p[1]), w >= 0, h >= 0 else {
        throw OptionError("\(flag) expects WxH, got '\(s)'")
    }
    return CGSize(width: w, height: h)
}
