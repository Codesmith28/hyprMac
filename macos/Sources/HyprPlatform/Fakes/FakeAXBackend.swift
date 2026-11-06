import CoreGraphics
import Foundation

/// `AXBackend` over a `FakeDesktop`, applying the injected quirks.
public final class FakeAXBackend: AXBackend, @unchecked Sendable {
    let desk: FakeDesktop
    /// Answer for `isTrusted` (stored on the desk).
    public var trusted: Bool {
        get { desk.locked { desk.axTrusted } }
        set { desk.locked { desk.axTrusted = newValue } }
    }
    /// Optional hit-test override (return nil to fall through to the default model). Stored on the desk.
    public var hitTestOverride: ((CGPoint) -> AXHit?)? {
        get { desk.locked { desk.axHitTestOverride } }
        set { desk.locked { desk.axHitTestOverride = newValue } }
    }
    /// Optional overrides for focused application / window. Stored on the desk.
    public var focusedApplicationOverride: (() -> pid_t?)? {
        get { desk.locked { desk.axFocusedApplicationOverride } }
        set { desk.locked { desk.axFocusedApplicationOverride = newValue } }
    }
    public var focusedWindowOverride: ((pid_t) -> WindowRef?)? {
        get { desk.locked { desk.axFocusedWindowOverride } }
        set { desk.locked { desk.axFocusedWindowOverride = newValue } }
    }

    init(_ desk: FakeDesktop) { self.desk = desk }

    /// Logs the call, applies hang / not-ready / closed / enhanced-UI delays (sleeping outside
    /// the lock), then runs `body` under the lock.
    private func call<T>(_ c: FakeAXCall, pid: pid_t, ref: WindowRef? = nil, _ body: () throws -> T) throws -> T {
        var delay: TimeInterval = 0
        var failure: AXBackendError?
        desk.locked {
            desk.callLog.append(c)
            guard let app = desk.appTable[pid] else { failure = .invalidUIElement; return }
            if app.hung {
                delay = min(app.hangDuration, TimeInterval(app.messagingTimeout))
                failure = .cannotComplete
                return
            }
            if let r = ref {
                guard let w = desk.windowTable[r] else { failure = .invalidUIElement; return }
                if w.quirks.notReadyCalls > 0 {
                    desk.windowTable[r]!.quirks.notReadyCalls -= 1
                    failure = .cannotComplete
                    return
                }
                if w.quirks.closesOnWrite && c.isWrite {
                    desk.windowTable[r] = nil
                    desk.zOrder.removeAll { $0 == r }
                    desk.emit(.window(.destroyed, pid: r.pid, window: r))
                    failure = .invalidUIElement
                    return
                }
            }
            if case .setSize = c, app.enhancedUI { delay = app.euiSlowDelay }
        }
        if delay > 0 { desk.sleeper(delay) }
        if let f = failure { throw f }
        return try desk.locked(body)
    }

    private func window(_ r: WindowRef) throws -> FakeDesktop.Window {
        guard let w = desk.windowTable[r] else { throw AXBackendError.invalidUIElement }
        return w
    }

    public func isTrusted(prompt: Bool) -> Bool { trusted }

    public func setMessagingTimeout(pid: pid_t, seconds: Float) {
        desk.locked {
            desk.callLog.append(.setMessagingTimeout(pid, seconds))
            desk.appTable[pid]?.messagingTimeout = seconds
        }
    }

    public func forget(pid: pid_t) {
        desk.locked { desk.forgottenPidList.append(pid) }
    }

    public func windows(pid: pid_t) throws -> [WindowRef] {
        try call(.windows(pid), pid: pid) { desk.zOrder.filter { $0.pid == pid && desk.windowTable[$0]?.inTransition != true } }
    }

    public func facts(of r: WindowRef) throws -> WindowFacts {
        try call(.facts(r), pid: r.pid, ref: r) {
            let w = try window(r)
            let app = desk.appTable[r.pid]!
            let main = desk.zOrder.first { $0.pid == r.pid && desk.windowTable[$0]?.minimized == false }
            return WindowFacts(role: w.role, subrole: w.minimized && w.quirks.minimizedReportsDialog ? "AXDialog" : w.subrole, title: w.title, frame: w.frame,
                               isMinimized: w.minimized, isFullscreen: w.fullscreen, isResizable: w.resizable,
                               isMain: main == r, isFocused: desk.focusedRef == r, bundleID: app.info.bundleID,
                               activationPolicy: app.info.activationPolicy, hasCloseButton: w.hasCloseButton,
                               minSize: w.quirks.exposesMinSize ? w.quirks.minSize : nil)
        }
    }

    public func frame(of r: WindowRef) throws -> CGRect {
        try call(.frame(r), pid: r.pid, ref: r) { try window(r).frame }
    }

    public func setPosition(_ origin: CGPoint, of r: WindowRef) throws {
        try call(.setPosition(r, origin), pid: r.pid, ref: r) {
            var w = try window(r)
            var o = origin
            if w.quirks.clampToDisplay,
               let d = DisplayGeometry.display(containing: origin, in: desk.displayList.map(\.info))
                ?? DisplayGeometry.display(for: CGRect(origin: origin, size: w.frame.size), in: desk.displayList.map(\.info)) {
                let vf = d.visibleFrame
                o.x = max(vf.minX, min(o.x, vf.maxX - w.frame.width))
                o.y = max(vf.minY, min(o.y, vf.maxY - w.frame.height))
            }
            let oldDisplay = desk.displayFor(w.frame)?.info.id
            w.frame.origin = o
            if let nd = desk.displayFor(w.frame), nd.info.id != oldDisplay, !w.fullscreen {
                w.space = nd.active // crossing displays changes Space
            }
            apply(w)
            desk.emit(.window(.moved, pid: r.pid, window: r))
        }
    }

    public func setSize(_ size: CGSize, of r: WindowRef) throws {
        try call(.setSize(r, size), pid: r.pid, ref: r) {
            var w = try window(r)
            guard w.resizable else { return }
            let previous = w.frame.size
            var s = size
            if let m = w.quirks.minSize { s.width = max(s.width, m.width); s.height = max(s.height, m.height) }
            if w.quirks.clampToDisplay, let d = desk.displayFor(w.frame) {
                let vf = d.info.visibleFrame
                s.width = min(s.width, vf.maxX - w.frame.minX)
                s.height = min(s.height, vf.maxY - w.frame.minY)
            }
            if let app = desk.appTable[r.pid], app.enhancedUI {
                s.width -= app.euiInaccuracy
                s.height -= app.euiInaccuracy
            }
            w.frame.size = w.quirks.snapsBack ? previous : s
            apply(w)
            desk.emit(.window(.resized, pid: r.pid, window: r))
        }
    }

    /// Writes the window back; native tabs share one frame.
    private func apply(_ w: FakeDesktop.Window) {
        desk.windowTable[w.ref] = w
        guard let g = w.tabGroup else { return }
        for (r, other) in desk.windowTable where r != w.ref && r.pid == w.ref.pid && other.tabGroup == g {
            desk.windowTable[r]!.frame = w.frame
            desk.windowTable[r]!.space = w.space
        }
    }

    public func bool(_ attribute: AXBoolAttribute, of r: WindowRef) throws -> Bool {
        try call(.bool(attribute, r), pid: r.pid, ref: r) {
            let w = try window(r)
            switch attribute {
            case .minimized: return w.minimized
            case .fullscreen: return w.fullscreen
            case .main: return desk.zOrder.first { $0.pid == r.pid } == r
            case .focused: return desk.focusedRef == r
            }
        }
    }

    public func setBool(_ attribute: AXBoolAttribute, _ value: Bool, of r: WindowRef) throws {
        try call(.setBool(attribute, value, r), pid: r.pid, ref: r) { _ = try window(r) }
        switch attribute {
        case .minimized: desk.setMinimized(r, value)
        case .fullscreen: desk.setFullscreen(r, value)
        case .main, .focused: if value { desk.focus(r) }
        }
    }

    public func enhancedUserInterface(pid: pid_t) throws -> Bool {
        try call(.enhancedUI(pid), pid: pid) { desk.appTable[pid]?.enhancedUI ?? false }
    }

    public func setEnhancedUserInterface(_ value: Bool, pid: pid_t) throws {
        try call(.setEnhancedUI(pid, value), pid: pid) { desk.appTable[pid]?.enhancedUI = value }
    }

    public func focusedApplication() throws -> pid_t? {
        desk.locked {
            desk.callLog.append(.focusedApplication)
            if let o = desk.axFocusedApplicationOverride { return o() }
            return desk.focusedPid
        }
    }

    public func focusedWindow(pid: pid_t) throws -> WindowRef? {
        try call(.focusedWindow(pid), pid: pid) {
            if let o = desk.axFocusedWindowOverride { return o(pid) }
            return desk.focusedRef?.pid == pid ? desk.focusedRef : nil
        }
    }

    /// Default model: the frontmost on-screen window under the point. Its top 28 pt are the
    /// titlebar: `titlebarRegions` hit as their role, elsewhere the window itself. Below is
    /// content (`AXScrollArea`).
    public func element(at point: CGPoint) throws -> AXHit? {
        desk.locked { desk.callLog.append(.elementAt(point)) }
        if let o = hitTestOverride, let hit = o(point) { return hit }
        return desk.locked { desk.hitTest(point) }
    }
}

extension FakeDesktop {
    func hitTest(_ point: CGPoint) -> AXHit? {
        guard let ref = zOrder.first(where: { r in
            guard let w = windowTable[r] else { return false }
            return onscreen(w) && w.frame.contains(point)
        }), let w = windowTable[ref] else { return nil }
        if point.y - w.frame.minY < 28 {
            let f = (point.x - w.frame.minX) / max(w.frame.width, 1)
            let dy = point.y - w.frame.minY
            if let region = w.quirks.titlebarRegions.first(where: {
                f >= $0.from && f < $0.to && dy >= $0.top && dy < $0.bottom
            }) {
                return AXHit(role: region.role, pid: ref.pid, window: region.resolvesWindow ? ref : nil)
            }
            return AXHit(role: "AXWindow", subrole: w.subrole, pid: ref.pid, window: ref, isWindowItself: true)
        }
        return AXHit(role: "AXScrollArea", pid: ref.pid, window: ref)
    }
}
