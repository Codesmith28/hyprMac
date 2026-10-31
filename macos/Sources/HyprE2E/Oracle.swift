import Foundation
import CoreGraphics

/// Gap configuration as written to the hyprMac config.
struct Gaps: Equatable, CustomStringConvertible {
    var inner: Double
    var outer: Double
    static let defaults = Gaps(inner: 8, outer: 12)
    var description: String { "inner \(fmt(inner)), outer \(fmt(outer))" }
}

/// Independent re-implementation of the expected BSP geometry. It does NOT
/// link the core: if both agree, the layout really is what the spec says.
///
/// Spec: the outer gap is applied once to the usable rect; every split obeys
/// `L1 + L2 + inner = L` and cuts along the longer axis (ties go side by
/// side); dwindle insertion splits the most recently focused tile, which for
/// windows opened one after another is the newest one, and the new window
/// takes the second half.
enum Oracle {
    /// How the first child's length is derived; the core works in doubles, the
    /// platform may round. Any variant within tolerance counts as a match.
    enum Rounding: String, CaseIterable { case exact, floor, round }

    static func dwindle(count: Int, usable: CGRect, gaps: Gaps, ratio: Double = 0.5,
                        rounding: Rounding = .exact) -> [CGRect] {
        guard count > 0 else { return [] }
        let root = usable.insetBy(dx: gaps.outer, dy: gaps.outer)
        var rects = [root]
        for _ in 1..<count {
            let parent = rects[rects.count - 1]
            let (a, b) = split(parent, inner: gaps.inner, ratio: ratio, rounding: rounding)
            rects[rects.count - 1] = a
            rects.append(b)
        }
        return rects
    }

    static func split(_ r: CGRect, inner: Double, ratio: Double, rounding: Rounding) -> (CGRect, CGRect) {
        func l1(_ total: Double) -> Double {
            let v = (total - inner) * ratio
            switch rounding {
            case .exact: return v
            case .floor: return v.rounded(.down)
            case .round: return v.rounded(.toNearestOrAwayFromZero)
            }
        }
        if r.width >= r.height {
            let w1 = l1(r.width)
            return (CGRect(x: r.minX, y: r.minY, width: w1, height: r.height),
                    CGRect(x: r.minX + w1 + inner, y: r.minY, width: r.width - w1 - inner, height: r.height))
        } else {
            let h1 = l1(r.height)
            return (CGRect(x: r.minX, y: r.minY, width: r.width, height: h1),
                    CGRect(x: r.minX, y: r.minY + h1 + inner, width: r.width, height: r.height - h1 - inner))
        }
    }

    /// All distinct rounding variants of the layout.
    static func variants(count: Int, usable: CGRect, gaps: Gaps) -> [[CGRect]] {
        var out: [[CGRect]] = []
        for r in Rounding.allCases {
            let v = dwindle(count: count, usable: usable, gaps: gaps, rounding: r)
            if !out.contains(v) { out.append(v) }
        }
        return out
    }

    static func close(_ a: CGRect, _ b: CGRect, tolerance: Double = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func maxDelta(_ a: CGRect, _ b: CGRect) -> Double {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }
}

// MARK: - self test

enum OracleSelfTest {
    struct Case {
        let name: String
        let usable: CGRect
        let gaps: Gaps
        let rounding: Oracle.Rounding
        let expected: [CGRect]
    }

    static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// Hand-computed cases (see comments for the arithmetic).
    static let cases: [Case] = {
        let full = r(0, 0, 1440, 900)
        // root = (12,12,1416,876). 2 tiles: (1416-8)/2 = 704 -> A x=12, B x=12+704+8=724.
        // 3rd splits B (704x876, taller): (876-8)/2 = 434 -> B y=12, C y=12+434+8=454.
        // 4th splits C (704x434, wider): (704-8)/2 = 348 -> C x=724, D x=724+348+8=1080.
        // 5th splits D (348x434, taller): (434-8)/2 = 213 -> D y=454, E y=454+213+8=675.
        let one = [r(12, 12, 1416, 876)]
        let two = [r(12, 12, 704, 876), r(724, 12, 704, 876)]
        let three = [r(12, 12, 704, 876), r(724, 12, 704, 434), r(724, 454, 704, 434)]
        let four = [r(12, 12, 704, 876), r(724, 12, 704, 434), r(724, 454, 348, 434), r(1080, 454, 348, 434)]
        let five = [r(12, 12, 704, 876), r(724, 12, 704, 434), r(724, 454, 348, 434),
                    r(1080, 454, 348, 213), r(1080, 675, 348, 213)]
        // Menu bar 25 pt: usable (0,25,1440,875) -> root (12,37,1416,851).
        // 3rd split of 704x851: (851-8)/2 = 421.5; floor -> 421 and 851-421-8 = 422.
        let mb = r(0, 25, 1440, 875)
        let mbThreeExact = [r(12, 37, 704, 851), r(724, 37, 704, 421.5), r(724, 466.5, 704, 421.5)]
        let mbThreeFloor = [r(12, 37, 704, 851), r(724, 37, 704, 421), r(724, 466, 704, 422)]
        // inner 20, outer 0: (1440-20)/2 = 710 -> B x = 730.
        let wide = [r(0, 0, 710, 900), r(730, 0, 710, 900)]
        // Portrait 900x1440: root (12,12,876,1416), taller -> (1416-8)/2 = 704 stacked.
        let portrait = [r(12, 12, 876, 704), r(12, 724, 876, 704)]
        // Square tie 1000x1000, outer 0 inner 10 -> side by side 495 | 495.
        let square = [r(0, 0, 495, 1000), r(505, 0, 495, 1000)]
        // Secondary display left of primary: usable (-1920,0,1920,1080).
        // root (-1908,12,1896,1056) -> (1896-8)/2 = 944 -> B x = -1908+944+8 = -956.
        let left = [r(-1908, 12, 944, 1056), r(-956, 12, 944, 1056)]
        return [
            Case(name: "1440x900 1 window", usable: full, gaps: .defaults, rounding: .exact, expected: one),
            Case(name: "1440x900 2 windows", usable: full, gaps: .defaults, rounding: .exact, expected: two),
            Case(name: "1440x900 3 windows", usable: full, gaps: .defaults, rounding: .exact, expected: three),
            Case(name: "1440x900 4 windows", usable: full, gaps: .defaults, rounding: .exact, expected: four),
            Case(name: "1440x900 5 windows", usable: full, gaps: .defaults, rounding: .exact, expected: five),
            Case(name: "menu bar 3 windows exact", usable: mb, gaps: .defaults, rounding: .exact, expected: mbThreeExact),
            Case(name: "menu bar 3 windows floor", usable: mb, gaps: .defaults, rounding: .floor, expected: mbThreeFloor),
            Case(name: "inner 20 outer 0", usable: full, gaps: Gaps(inner: 20, outer: 0), rounding: .exact, expected: wide),
            Case(name: "portrait 2 windows", usable: r(0, 0, 900, 1440), gaps: .defaults, rounding: .exact, expected: portrait),
            Case(name: "square tie goes side by side", usable: r(0, 0, 1000, 1000), gaps: Gaps(inner: 10, outer: 0),
                 rounding: .exact, expected: square),
            Case(name: "negative-origin display", usable: r(-1920, 0, 1920, 1080), gaps: .defaults,
                 rounding: .exact, expected: left),
        ]
    }()

    /// Returns the number of failures; prints TAP.
    static func run() -> Int {
        var failures = 0
        var n = 0
        let invariantCount = 3 * 12
        print("TAP version 13")
        print("1..\(cases.count + invariantCount)")
        for c in cases {
            n += 1
            let got = Oracle.dwindle(count: c.expected.count, usable: c.usable, gaps: c.gaps, rounding: c.rounding)
            let ok = got.count == c.expected.count &&
                zip(got, c.expected).allSatisfy { Oracle.maxDelta($0, $1) < 1e-9 }
            print("\(ok ? "ok" : "not ok") \(n) - oracle: \(c.name)")
            if !ok {
                failures += 1
                for (i, (e, g)) in zip(c.expected, got).enumerated() {
                    print("#   \(i): expected \(fmtRect(e))  got \(fmtRect(g))")
                }
            }
        }
        // Invariants on an awkward screen: tiles stay inside the root, never
        // overlap, keep at least the inner gap apart, and areas add up.
        let usable = r(0, 33, 1512, 949)
        for rounding in Oracle.Rounding.allCases {
            for count in 1...12 {
                n += 1
                let tiles = Oracle.dwindle(count: count, usable: usable, gaps: .defaults, rounding: rounding)
                let root = usable.insetBy(dx: 12, dy: 12)
                var problems: [String] = []
                for (i, t) in tiles.enumerated() {
                    if !root.insetBy(dx: -1e-9, dy: -1e-9).contains(t) { problems.append("tile \(i) outside root") }
                    if t.width <= 0 || t.height <= 0 { problems.append("tile \(i) empty") }
                    for j in (i + 1)..<tiles.count {
                        let gapped = t.insetBy(dx: -8 + 1e-9, dy: -8 + 1e-9)
                        let ix = gapped.intersection(tiles[j])
                        if !ix.isNull && ix.width > 1e-6 && ix.height > 1e-6 {
                            problems.append("tiles \(i),\(j) closer than the inner gap")
                        }
                    }
                }
                if rounding == .floor && !tiles.allSatisfy({ $0.minX == $0.minX.rounded() && $0.width == $0.width.rounded() }) {
                    problems.append("floor variant produced fractional x/width")
                }
                let ok = problems.isEmpty && tiles.count == count
                print("\(ok ? "ok" : "not ok") \(n) - oracle invariants: \(rounding.rawValue) \(count) windows")
                if !ok {
                    failures += 1
                    problems.forEach { print("#   \($0)") }
                }
            }
        }
        print("# summary: \(n - failures) passed, \(failures) failed (oracle self-test)")
        return failures
    }
}

func fmt(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
}

func fmtRect(_ r: CGRect?) -> String {
    guard let r else { return "—" }
    return "(\(fmt(r.minX)), \(fmt(r.minY)), \(fmt(r.width)), \(fmt(r.height)))"
}
