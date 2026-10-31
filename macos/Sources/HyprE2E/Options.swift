import Foundation

struct Options {
    var app: URL?
    var fixture: URL?
    var scenarios: [String] = []
    var list = false
    var keepGoing = false
    var timeout: Double = 60
    var oracleSelfTest = false
    var fixtureSelfTest = false
    var hideOthers = true
    var stagger = 400

    static let usage = """
    usage: hyprmac-e2e --app PATH --fixture PATH [--scenario NAME ...] [--list] [--keep-going]
                       [--timeout S] [--oracle-selftest] [--fixture-selftest]
                       [--no-hide-others] [--stagger MS]

      --app PATH          hyprMac.app to test (launched with --config/--event-log)
      --fixture PATH      hyprmac-fixture binary (default: next to this binary)
      --scenario NAME     run only these scenarios (repeatable or comma-separated)
      --list              list scenarios and exit
      --keep-going        keep running after a failure (default: stop at the first)
      --timeout S         per-scenario time limit (default 60)
      --oracle-selftest   check the geometry oracle against hand-computed layouts (no permissions)
      --fixture-selftest  launch the fixture, read its windows, quit it (no hyprMac, no input events)
      --no-hide-others    do not hide other apps during the run (their windows will be tiled too)
      --stagger MS        delay between fixture windows (default 400)

    exit status: 0 all passed or skipped, 1 a scenario failed, 2 preflight/usage error
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) -> String {
            i += 1
            guard i < args.count else { usageError("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--app": o.app = URL(fileURLWithPath: value(a)).standardizedFileURL
            case "--fixture": o.fixture = URL(fileURLWithPath: value(a)).standardizedFileURL
            case "--scenario":
                o.scenarios += value(a).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "--list": o.list = true
            case "--keep-going": o.keepGoing = true
            case "--timeout":
                let v = value(a)
                guard let t = Double(v), t > 0 else { usageError("--timeout: bad value '\(v)'") }
                o.timeout = t
            case "--oracle-selftest": o.oracleSelfTest = true
            case "--fixture-selftest": o.fixtureSelfTest = true
            case "--no-hide-others": o.hideOthers = false
            case "--stagger":
                let v = value(a)
                guard let s = Int(v), s >= 0 else { usageError("--stagger: bad value '\(v)'") }
                o.stagger = s
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                usageError("unknown option '\(a)'")
            }
            i += 1
        }
        if o.fixture == nil, let me = Bundle.main.executableURL {
            o.fixture = me.deletingLastPathComponent().appendingPathComponent("hyprmac-fixture")
        }
        return o
    }
}

func usageError(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("hyprmac-e2e: \(msg)\n\n\(Options.usage)\n".utf8))
    exit(2)
}

func preflightError(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("hyprmac-e2e: preflight: \(msg)\n".utf8))
    exit(2)
}
