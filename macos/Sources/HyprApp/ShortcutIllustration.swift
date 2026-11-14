import SwiftUI

/// Looping vector animation for one shortcut, drawn on a 88×56 canvas.
/// Static (a representative frame) when Reduce Motion is on.
struct ShortcutIllustration: View {
    let kind: CheatsheetEntry.Illustration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 3.2
    private static let stillPhase = 0.42

    var body: some View {
        if reduceMotion {
            canvas(phase: Self.stillPhase)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                canvas(phase: (t / Self.period).truncatingRemainder(dividingBy: 1))
            }
        }
    }

    private func canvas(phase: Double) -> some View {
        Canvas { gc, size in
            // Fixed 88×56 design space, scaled to whatever frame we're given.
            let s = min(size.width / 88, size.height / 56)
            gc.translateBy(x: (size.width - 88 * s) / 2, y: (size.height - 56 * s) / 2)
            gc.scaleBy(x: s, y: s)
            Art.draw(kind, in: &gc, phase: phase)
        }
    }
}

// MARK: - drawing

private enum Art {
    static let accent = Color.accentColor
    static let ink = Color.primary

    static func draw(_ kind: CheatsheetEntry.Illustration, in gc: inout GraphicsContext, phase p: Double) {
        switch kind {
        case .switchDesktop: switchDesktop(&gc, p)
        case .throwWindow: throwWindow(&gc, p)
        case .focus: focus(&gc, p)
        case .swap: swap(&gc, p)
        case .reSplit: reSplit(&gc, p)
        case .toggleFloat: toggleFloat(&gc, p)
        case .center: center(&gc, p)
        case .help: help(&gc, p)
        }
    }

    // Easing helpers ---------------------------------------------------------

    /// 0…1 progress of `p` between `a` and `b`, eased.
    static func seg(_ p: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(max((p - a) / (b - a), 0), 1)
        return x * x * (3 - 2 * x)
    }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    static func round(_ r: CGRect, _ radius: CGFloat = 3) -> Path { Path(roundedRect: r, cornerRadius: radius, style: .continuous) }

    static func tile(_ gc: inout GraphicsContext, _ r: CGRect, fill: Color = ink.opacity(0.10),
                     stroke: Color = ink.opacity(0.22), width: CGFloat = 1) {
        let path = round(r)
        gc.fill(path, with: .color(fill))
        gc.stroke(path, with: .color(stroke), lineWidth: width)
    }
    static func hot(_ gc: inout GraphicsContext, _ r: CGRect) {
        let path = round(r)
        gc.fill(path, with: .color(accent.opacity(0.28)))
        gc.stroke(path, with: .color(accent), lineWidth: 1.5)
    }

    /// Three-tile BSP layout inside a screen outline: big left, two stacked right.
    static let screen = CGRect(x: 10, y: 6, width: 68, height: 44)
    static let bsp: [CGRect] = [
        CGRect(x: 14, y: 10, width: 33, height: 36),
        CGRect(x: 51, y: 10, width: 23, height: 17),
        CGRect(x: 51, y: 29, width: 23, height: 17),
    ]
    static func screenFrame(_ gc: inout GraphicsContext) {
        gc.stroke(round(screen, 5), with: .color(ink.opacity(0.18)), lineWidth: 1)
    }

    // Illustrations ----------------------------------------------------------

    /// Highlight hops across three desktops and back.
    static func switchDesktop(_ gc: inout GraphicsContext, _ p: Double) {
        let w = 22.0, h = 26.0, gap = 6.0, y = 12.0
        let x0 = (88 - (3 * w + 2 * gap)) / 2
        let pos = 2 * (seg(p, 0.12, 0.3) * 0.5 + seg(p, 0.3, 0.5) * 0.5)
              - 2 * seg(p, 0.78, 0.95)
        for i in 0..<3 {
            tile(&gc, CGRect(x: x0 + Double(i) * (w + gap), y: y, width: w, height: h), fill: ink.opacity(0.06))
        }
        let hx = x0 + pos * (w + gap)
        hot(&gc, CGRect(x: hx, y: y, width: w, height: h))
        for i in 0..<3 {
            let on = max(0, 1 - abs(pos - Double(i)))
            let dot = Path(ellipseIn: CGRect(x: 44 - 8 + Double(i) * 8 - 1.75, y: 46, width: 3.5, height: 3.5))
            gc.fill(dot, with: .color(on > 0.5 ? accent : ink.opacity(0.22)))
        }
    }

    /// A window leaves one desktop and lands on another.
    static func throwWindow(_ gc: inout GraphicsContext, _ p: Double) {
        let a = CGRect(x: 8, y: 8, width: 30, height: 40)
        let b = CGRect(x: 50, y: 8, width: 30, height: 40)
        tile(&gc, a, fill: ink.opacity(0.06)); tile(&gc, b, fill: ink.opacity(0.06))
        let t = seg(p, 0.2, 0.55)
        let from = CGRect(x: 13, y: 16, width: 20, height: 24)
        let to = CGRect(x: 55, y: 16, width: 20, height: 24)
        var r = lerp(from, to, t)
        r.origin.y -= sin(t * .pi) * 8
        let fade = 1 - seg(p, 0.88, 0.97) + seg(p, 0.97, 1.0)
        let scale = 1 - 0.18 * sin(t * .pi)
        let c = CGPoint(x: r.midX, y: r.midY)
        r = CGRect(x: c.x - r.width * scale / 2, y: c.y - r.height * scale / 2, width: r.width * scale, height: r.height * scale)
        var layer = gc
        layer.opacity = min(max(fade, 0), 1)
        hot(&layer, r)
        // trail
        if t > 0 && t < 1 {
            var path = Path()
            path.move(to: CGPoint(x: from.midX, y: from.midY))
            path.addQuadCurve(to: CGPoint(x: to.midX, y: to.midY), control: CGPoint(x: 44, y: 4))
            layer.opacity = 0.25 * min(max(fade, 0), 1)
            layer.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    /// Focus ring walks the tiles.
    static func focus(_ gc: inout GraphicsContext, _ p: Double) {
        screenFrame(&gc)
        for r in bsp { tile(&gc, r) }
        let path: [(Double, Double, Int, Int)] = [(0.1, 0.25, 0, 1), (0.4, 0.55, 1, 2), (0.7, 0.85, 2, 0)]
        var ring = bsp[0]
        for (a, b, from, to) in path where p >= a { ring = lerp(bsp[from], bsp[to], seg(p, a, b)) }
        hot(&gc, ring)
    }

    /// Two tiles trade places.
    static func swap(_ gc: inout GraphicsContext, _ p: Double) {
        screenFrame(&gc)
        tile(&gc, bsp[2])
        let t = seg(p, 0.15, 0.4) - seg(p, 0.6, 0.85)
        let moving = lerp(bsp[0], bsp[1], t)
        let other = lerp(bsp[1], bsp[0], t)
        tile(&gc, other)
        hot(&gc, moving)
    }

    /// A tile is dragged onto the bottom edge of its neighbour; the pair re-splits from side by side to stacked.
    static func reSplit(_ gc: inout GraphicsContext, _ p: Double) {
        screenFrame(&gc)
        let m = seg(p, 0.38, 0.56) - seg(p, 0.78, 0.94)
        let a = lerp(CGRect(x: 14, y: 10, width: 29, height: 36), CGRect(x: 14, y: 29, width: 60, height: 17), m)
        let b = lerp(CGRect(x: 47, y: 10, width: 27, height: 36), CGRect(x: 14, y: 10, width: 60, height: 17), m)
        tile(&gc, b)
        // Drop zone on the neighbour's bottom edge, lit while the dragged tile hovers there.
        let drag = seg(p, 0.08, 0.3) * (1 - seg(p, 0.34, 0.4))
        if drag > 0.01 {
            var zone = gc
            zone.opacity = drag
            zone.fill(round(CGRect(x: 47, y: 37, width: 27, height: 9), 3), with: .color(accent.opacity(0.35)))
            let from = CGPoint(x: a.midX, y: a.midY), to = CGPoint(x: 60.5, y: 38)
            let c = CGPoint(x: lerp(from.x, to.x, drag), y: lerp(from.y, to.y, drag))
            hot(&zone, CGRect(x: c.x - 9, y: c.y - 6, width: 18, height: 12))
            tile(&gc, a, fill: ink.opacity(0.04), stroke: ink.opacity(0.12))
        } else {
            hot(&gc, a)
        }
    }

    /// One tile pops out as a floating window and drops back in.
    static func toggleFloat(_ gc: inout GraphicsContext, _ p: Double) {
        screenFrame(&gc)
        let t = seg(p, 0.15, 0.4) - seg(p, 0.6, 0.85)
        let leftTiled = CGRect(x: 14, y: 10, width: 29, height: 36)
        let leftFull = CGRect(x: 14, y: 10, width: 60, height: 36)
        let rightTiled = CGRect(x: 47, y: 10, width: 27, height: 36)
        let rightFloat = CGRect(x: 34, y: 17, width: 30, height: 24)
        tile(&gc, lerp(leftTiled, leftFull, t))
        let r = lerp(rightTiled, rightFloat, t)
        var shadow = gc
        shadow.opacity = 0.35 * t
        shadow.fill(round(r.offsetBy(dx: 0, dy: 3).insetBy(dx: 1, dy: 0), 4), with: .color(.black))
        hot(&gc, r)
    }

    /// A small window glides from a corner to the middle; crosshair confirms.
    static func center(_ gc: inout GraphicsContext, _ p: Double) {
        screenFrame(&gc)
        let t = seg(p, 0.15, 0.45) - seg(p, 0.65, 0.9)
        let corner = CGRect(x: 48, y: 28, width: 24, height: 16)
        let mid = CGRect(x: screen.midX - 12, y: screen.midY - 8, width: 24, height: 16)
        var cross = gc
        cross.opacity = 0.5 * t
        var v = Path(); v.move(to: CGPoint(x: screen.midX, y: screen.minY + 3)); v.addLine(to: CGPoint(x: screen.midX, y: screen.maxY - 3))
        var h = Path(); h.move(to: CGPoint(x: screen.minX + 3, y: screen.midY)); h.addLine(to: CGPoint(x: screen.maxX - 3, y: screen.midY))
        let dash = StrokeStyle(lineWidth: 1, dash: [2, 3])
        cross.stroke(v, with: .color(accent), style: dash)
        cross.stroke(h, with: .color(accent), style: dash)
        hot(&gc, lerp(corner, mid, t))
    }

    /// A keycap is pressed and the cheatsheet panel opens.
    static func help(_ gc: inout GraphicsContext, _ p: Double) {
        let press = seg(p, 0.08, 0.16) - seg(p, 0.16, 0.26)
        let cap = CGRect(x: 8, y: 14 + press * 2, width: 28, height: 28 - press * 2)
        tile(&gc, cap, fill: ink.opacity(0.10), stroke: ink.opacity(0.3), width: 1)
        gc.draw(Text("?").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(ink.opacity(0.8)),
                at: CGPoint(x: cap.midX, y: cap.midY), anchor: .center)

        let open = seg(p, 0.22, 0.42) * (1 - seg(p, 0.86, 0.97))
        guard open > 0.01 else { return }
        let full = CGRect(x: 44, y: 8, width: 36, height: 40)
        let r = CGRect(x: full.midX - full.width * open / 2, y: full.midY - full.height * open / 2,
                       width: full.width * open, height: full.height * open)
        var layer = gc
        layer.opacity = open
        hot(&layer, r)
        for i in 0..<3 {
            let bar = CGRect(x: r.minX + 5 * open, y: r.minY + (8 + Double(i) * 10) * open, width: (26 - Double(i) * 6) * open, height: 3 * open)
            layer.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(ink.opacity(0.35)))
        }
    }
}
