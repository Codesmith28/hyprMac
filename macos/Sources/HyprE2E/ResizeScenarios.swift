import AppKit

// Hyprland-style user resize: a REAL mouse drag on a tiled window's edge moves the split.
// Posts synthetic mouse events, so it is only run by the orchestrator under supervision.

extension Catalog {
    /// Posts a left-button drag from `from` to `to` (top-left global points): mouse-down, a few
    /// mouse-dragged steps, mouse-up. The pointer is parked back where it was afterwards.
    static func mouseDrag(from: CGPoint, to: CGPoint, steps: Int = 8) {
        let src = CGEventSource(stateID: .hidSystemState)
        let origin = Keys.cursor
        func post(_ type: CGEventType, _ p: CGPoint) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { return }
            e.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, from)
        pump(0.15)
        post(.leftMouseDown, from)
        pump(0.15)
        // The first dragged event only arms the resize (the window ignores it): spend a 1 pt one on it.
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x > from.x ? 1 : -1), y: from.y))
        pump(0.05)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            pump(0.04)
        }
        for _ in 0..<3 { // let the window catch up with the pointer before releasing
            post(.leftMouseDragged, to)
            pump(0.05)
        }
        pump(0.1)
        post(.leftMouseUp, to)
        pump(0.1)
        post(.mouseMoved, origin)
    }

    static let userResize = Scenario(
        name: "user-resize",
        summary: "dragging window A's right edge +200 then -150 moves the split; B reflows, no snap back") { ctx in
        try ctx.startHypr()
        let log = try ctx.log
        let f = try ctx.launchFixture(2)
        let r = try (0..<2).map(f.ref)
        try ctx.expectOracle(r, "2 windows tiled before the drag")
        let usable = ctx.screen.visible
        let gap = ctx.gaps.inner

        func drag(_ delta: CGFloat, _ what: String) throws {
            guard let a0 = Frames.measure([r[0]])[0].best, let b0 = Frames.measure([r[1]])[0].best else {
                throw HarnessError("windows not measurable before the drag")
            }
            let c = log.cursor
            // 2 pt inside A's right edge, mid-height.
            let start = CGPoint(x: a0.maxX - 2, y: a0.midY)
            mouseDrag(from: start, to: CGPoint(x: start.x + delta, y: start.y))
            guard log.waitFor("user_resize", after: c, timeout: 5) != nil else {
                throw HarnessError("\(what): no user_resize event (did the drag grab the edge?)", details: log.tail())
            }
            let wantA = a0.width + delta
            _ = try ctx.expectFrames(r, what) { m in
                guard let a = m[0].best, let b = m[1].best else { return ["a window was not measurable"] }
                var p: [String] = []
                if abs(a.width - wantA) > 2 { p.append("A is \(fmt(a.width)) wide; expected \(fmt(wantA)) ±2") }
                if abs(b.minX - (a.maxX + gap)) > 2 { p.append("B.x is \(fmt(b.minX)); expected A.maxX + \(fmt(gap)) = \(fmt(a.maxX + gap))") }
                if delta > 0, b.width >= b0.width - 1 { p.append("B did not shrink (\(fmt(b0.width)) → \(fmt(b.width)))") }
                if delta < 0, b.width <= b0.width + 1 { p.append("B did not grow (\(fmt(b0.width)) → \(fmt(b.width)))") }
                for (name, w) in [("A", a), ("B", b)] where !usable.insetBy(dx: -1, dy: -1).contains(w) {
                    p.append("\(name) \(fmtRect(w)) is outside usable \(fmtRect(usable))")
                }
                return p
            }
        }

        try drag(200, "A's right edge dragged +200")
        try drag(-150, "the shared edge dragged back -150")
        if log.events.contains(where: { $0.name == "floated" && $0.string("reason") == "fights" }) {
            throw HarnessError("a user resize was counted as a fight (a window floated)", details: log.tail())
        }
    }
}
