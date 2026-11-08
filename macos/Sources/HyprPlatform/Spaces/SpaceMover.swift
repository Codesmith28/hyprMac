import CoreGraphics
import Foundation

public enum SpaceMoveResult: Equatable, Sendable {
    case moved
    case alreadyThere
    /// `available` is nil when native Spaces are unavailable (count unknown).
    case noSuchSpace(requested: Int, available: Int?)
    case refusedFullscreen
    case noGrabPoint
    case timedOut
    /// A Space transition is still animating; a ⌥N now would be silently dropped. Retry later.
    case transitionInFlight
    case failed(AXBackendError)
}

/// Throws a window to user Space N with the drag trick: hold the window by its titlebar,
/// post the native "Switch to Desktop N" shortcut (⌥N by default), wait for the Space change to land and settle, release.
///
/// `move` blocks for up to `switchTimeout + settle` (~1.5 s); call it on its own queue.
public final class SpaceMover {
    public struct Configuration: Sendable {
        /// Below the window's top edge (6–10 pt band).
        public var titlebarOffset: CGFloat = 8
        /// Offset of the "just right of the traffic lights" candidate.
        public var trafficLightsOffset: CGFloat = 80
        /// Pause between mouse-down and the key press.
        public var pressDelay: TimeInterval = 0.02
        public var pollInterval: TimeInterval = 0.01
        /// How long to wait for the active Space to become the target.
        public var switchTimeout: TimeInterval = 1.0
        /// Extra wait after the Space changed before releasing (animation still running).
        public var settle: TimeInterval = 0.12
        /// When no candidate at `titlebarOffset` is usable (e.g. the titlebar is all tab buttons,
        /// as in Ghostty with native tabs), also try the thin band at `thinBandOffset` below the
        /// top edge, where the window itself is hit. Needs live validation: a mouse-down this
        /// close to the edge could start a resize in some apps.
        public var thinBandFallback = true
        public var thinBandOffset: CGFloat = 3
        /// When primary candidates (at titlebarOffset and thinBandOffset) fail (e.g. apps with tabs,
        /// centered search bars / command palettes, or custom toolbars), sample a finer grid across
        /// the titlebar band to find an acceptable grab area.
        public var fineGridFallback = true
        public var fineGridYOffsets: [CGFloat] = [1, 2, 4, 8, 14, 20]
        /// Whether to dynamically inspect and target safe titlebar gaps between and around traffic light buttons.
        public var trafficLightsFallback = true
        /// What to do if physical Shift is still held (the user is still on ⌥⇧N) before ⌥N.
        public var shiftRelease: ShiftReleasePolicy = .waitUpTo(0.04)
        public var shiftPollInterval: TimeInterval = 0.01
        public init() {}
    }

    public enum ShiftReleasePolicy: Equatable, Sendable {
        /// Wait (at most this long) for physical Shift to be released, then post anyway.
        case waitUpTo(TimeInterval)
        /// Post ⌥N right away.
        case postImmediately
    }

    /// What happened with physical Shift before the last ⌥N (logged as well).
    public enum ShiftOutcome: Equatable, Sendable {
        case notHeld
        case released(afterSeconds: TimeInterval)
        case postedWhileHeld
    }

    /// Roles that are controls, never a grab point.
    public static let rejectedRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXTab", "AXTextField", "AXSearchField",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXCheckBox",
        "AXColorWell", "AXIncrementor", "AXScrollBar", "AXProgressIndicator"
    ]
    /// Non-window roles accepted when they belong to the window (titlebar / tab-strip / unified toolbar area).
    public static let acceptedAreaRoles: Set<String> = [
        "AXGroup", "AXUnknown", "AXToolbar", "AXTabGroup", "AXStaticText",
        "AXHeading", "AXImage", "AXGenericElement", "AXSplitGroup"
    ]

    private let ax: AXBackend
    private let spaces: SpaceProvider
    private let displays: DisplayProvider
    private let poster: EventPoster
    private let clock: TimeSource
    private let transitions: SpaceTransitionGuard?
    private let windowServer: WindowServerQuery?
    private let nativeShortcuts: NativeSwitchShortcuts?
    private let flagsLock = NSLock()
    private var fallbackFlags: CGEventFlags = .maskAlternate
    public var configuration: Configuration
    /// Shift handling of the most recent throw that reached the key press.
    public private(set) var lastShiftOutcome: ShiftOutcome?

    public init(ax: AXBackend, spaces: SpaceProvider, displays: DisplayProvider, poster: EventPoster,
                clock: TimeSource = SystemTimeSource(), transitions: SpaceTransitionGuard? = nil,
                windowServer: WindowServerQuery? = nil, nativeShortcuts: NativeSwitchShortcuts? = nil,
                configuration: Configuration = Configuration()) {
        self.windowServer = windowServer
        self.nativeShortcuts = nativeShortcuts
        self.ax = ax
        self.spaces = spaces
        self.displays = displays
        self.poster = poster
        self.clock = clock
        self.transitions = transitions
        self.configuration = configuration
    }

    /// Modifiers to post when the native shortcut can't be read (the configured `keys.switch`).
    public var fallbackSwitchFlags: CGEventFlags {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return fallbackFlags }
        set { flagsLock.lock(); fallbackFlags = newValue; flagsLock.unlock() }
    }

    /// The modifiers of the ACTUAL native "Switch to Desktop N" shortcut (symbolichotkeys), or
    /// `fallbackSwitchFlags` when it isn't readable / enabled.
    public func switchFlags(forDesktop n: Int) -> CGEventFlags {
        nativeShortcuts?.enabledModifiers()[n] ?? fallbackSwitchFlags
    }

    /// Candidate grab points: `titlebarOffset` below the top edge at 25 %, 50 %, 75 % of the
    /// width and at `trafficLightsOffset` from the left edge (clamped inside the window).
    public static func grabCandidates(for frame: CGRect, titlebarOffset: CGFloat = 8,
                                      trafficLightsOffset: CGFloat = 80) -> [CGPoint] {
        let y = frame.minY + titlebarOffset
        let xs = [0.25, 0.5, 0.75].map { frame.minX + frame.width * $0 } +
            [min(frame.minX + trafficLightsOffset, frame.maxX - 1)]
        return xs.map { CGPoint(x: $0, y: y) }
    }

    /// A hit is a safe grab point if it is the window itself, or an accepted area role
    /// of that same window. Controls (tabs, buttons, fields, etc.) are rejected.
    public static func isAcceptableGrab(_ hit: AXHit?, for window: WindowRef) -> Bool {
        guard let hit, !rejectedRoles.contains(hit.role) else { return false }
        let belongsToWindow = (hit.window == window) || (hit.isWindowItself && hit.pid == window.pid)
        guard belongsToWindow else { return false }
        if hit.isWindowItself || hit.role == "AXWindow" { return true }
        return acceptedAreaRoles.contains(hit.role)
    }

    /// All candidates in primary search order: the normal band, then (if enabled) the thin band.
    public func candidates(for frame: CGRect) -> [CGPoint] {
        var pts = Self.grabCandidates(for: frame, titlebarOffset: configuration.titlebarOffset,
                                      trafficLightsOffset: configuration.trafficLightsOffset)
        if configuration.thinBandFallback {
            pts += Self.grabCandidates(for: frame, titlebarOffset: configuration.thinBandOffset,
                                       trafficLightsOffset: configuration.trafficLightsOffset)
        }
        return pts
    }

    /// Dynamically finds grab points in the safe non-control spaces between and around the traffic light buttons.
    /// This corner is universally titlebar in macOS and immune to full tab bars or centered search bars.
    public func trafficLightCandidates(for window: WindowRef, frame: CGRect, close: CGRect?, mini: CGRect?, zoom: CGRect?) -> [CGPoint] {
        guard configuration.trafficLightsFallback else { return [] }
        var pts: [CGPoint] = []
        if let c = close, let m = mini {
            // Gap between Close (red) and Minimize (yellow)
            pts.append(CGPoint(x: (c.maxX + m.minX) / 2, y: (c.midY + m.midY) / 2))
        }
        if let m = mini, let z = zoom {
            // Gap between Minimize (yellow) and Zoom/Fullscreen (green)
            pts.append(CGPoint(x: (m.maxX + z.minX) / 2, y: (m.midY + z.midY) / 2))
        }
        if let z = zoom {
            // Just right of Zoom button
            pts.append(CGPoint(x: z.maxX + 6, y: z.midY))
        }
        if let c = close, configuration.thinBandFallback {
            // Thin margin above close button
            pts.append(CGPoint(x: c.midX, y: max(frame.minY + 2, c.minY - 3)))
        }
        return pts
    }

    /// Finer grid of candidate grab points across the titlebar band (avoiding traffic lights and right margin).
    public func fineGridCandidates(for frame: CGRect) -> [CGPoint] {
        let minX = frame.minX + max(configuration.trafficLightsOffset, 70)
        let maxX = frame.maxX - 16
        guard maxX > minX else { return [] }
        let fractions: [CGFloat] = [0.15, 0.20, 0.30, 0.35, 0.40, 0.45, 0.55, 0.60, 0.65, 0.70, 0.80, 0.85, 0.90]
        var xs: [CGFloat] = []
        let nearTrafficLights = [
            frame.minX + configuration.trafficLightsOffset + 10,
            frame.minX + configuration.trafficLightsOffset + 25,
        ]
        for x in nearTrafficLights {
            if x >= minX && x <= maxX && !xs.contains(where: { abs($0 - x) < 0.5 }) {
                xs.append(x)
            }
        }
        for f in fractions {
            let x = frame.minX + frame.width * f
            if x >= minX && x <= maxX && !xs.contains(where: { abs($0 - x) < 0.5 }) {
                xs.append(x)
            }
        }
        let rightEdge = [
            maxX - 80,
            maxX - 40,
        ]
        for x in rightEdge {
            if x >= minX && x <= maxX && !xs.contains(where: { abs($0 - x) < 0.5 }) {
                xs.append(x)
            }
        }
        if xs.isEmpty { xs.append((minX + maxX) / 2) }
        let primary = candidates(for: frame)
        var pts: [CGPoint] = []
        for yOffset in configuration.fineGridYOffsets {
            let y = frame.minY + yOffset
            guard y < frame.maxY - 1 else { continue }
            for x in xs {
                let p = CGPoint(x: x, y: y)
                if !primary.contains(where: { abs($0.x - p.x) < 0.5 && abs($0.y - p.y) < 0.5 }) {
                    pts.append(p)
                }
            }
        }
        return pts
    }

    /// The topmost on-screen layer-0 window containing `point` (window-server truth).
    public static func topmostWindow(at point: CGPoint, in onscreen: [OnscreenWindow]) -> CGWindowID? {
        onscreen.first { $0.layer == 0 && $0.isOnscreen && $0.bounds.contains(point) }?.id
    }

    /// Checks whether the window server agrees the target window (or its child/accessory surface) is topmost at `point`.
    public static func isWindowServerAgreement(
        at point: CGPoint,
        target: WindowRef,
        frame: CGRect,
        hit: AXHit?,
        in onscreen: [OnscreenWindow]
    ) -> Bool {
        guard let top = onscreen.first(where: { $0.layer == 0 && $0.isOnscreen && $0.bounds.contains(point) }) else {
            return true
        }
        if top.id == target.windowID { return true }
        if let hitWin = hit?.window, top.id == hitWin.windowID { return true }
        if top.pid == target.pid { return true }
        return false
    }

    /// First candidate whose AX hit is an acceptable grab for `window` AND where the window
    /// server agrees `window` is the topmost layer-0 window (guards against overlaps and AX
    /// resolving to the wrong window).
    public func findGrabPoint(for window: WindowRef, frame: CGRect) -> CGPoint? {
        let onscreen = windowServer?.onscreenWindows()

        // 1. Dynamic traffic light gaps (highest priority when real AX buttons exist)
        let (close, mini, zoom) = ax.trafficLightButtons(of: window)
        if close != nil || mini != nil || zoom != nil {
            for p in trafficLightCandidates(for: window, frame: frame, close: close, mini: mini, zoom: zoom) {
                let hit = try? ax.element(at: p)
                guard Self.isAcceptableGrab(hit, for: window) else { continue }
                if let list = onscreen, !Self.isWindowServerAgreement(at: p, target: window, frame: frame, hit: hit, in: list) {
                    continue
                }
                Log.mover.debug("grab point found in traffic light area at \(p.debugDescription)")
                return p
            }
        }

        // 2. Primary candidates
        for p in candidates(for: frame) {
            let hit = try? ax.element(at: p)
            guard Self.isAcceptableGrab(hit, for: window) else {
                Log.mover.debug("grab candidate \(p.debugDescription) rejected: \(hit?.role ?? "nil")")
                continue
            }
            if let list = onscreen, !Self.isWindowServerAgreement(at: p, target: window, frame: frame, hit: hit, in: list) {
                Log.mover.debug("grab candidate \(p.debugDescription) rejected: another window is on top")
                continue
            }
            return p
        }

        // 3. Fine grid candidates
        if configuration.fineGridFallback {
            for p in fineGridCandidates(for: frame) {
                let hit = try? ax.element(at: p)
                guard Self.isAcceptableGrab(hit, for: window) else {
                    Log.mover.debug("fine grid candidate \(p.debugDescription) rejected: \(hit?.role ?? "nil")")
                    continue
                }
                if let list = onscreen, !Self.isWindowServerAgreement(at: p, target: window, frame: frame, hit: hit, in: list) {
                    Log.mover.debug("fine grid candidate \(p.debugDescription) rejected: another window is on top")
                    continue
                }
                Log.mover.debug("grab point found via fine grid at \(p.debugDescription)")
                return p
            }
        }
        return nil
    }

    /// Physical Shift still down (the user is still on ⌥⇧N) may stop macOS from recognising
    /// the synthetic ⌥N as "Switch to Desktop N". Wait per `shiftRelease`, and log the outcome.
    private func waitForShiftRelease(posting flags: CGEventFlags) -> ShiftOutcome {
        guard !flags.contains(.maskShift) else { return .notHeld } // a ⇧ shortcut needs no release
        guard poster.physicalModifierFlags().contains(.maskShift) else { return .notHeld }
        let start = clock.now()
        if case .waitUpTo(let limit) = configuration.shiftRelease {
            while clock.now() - start < limit {
                clock.sleep(configuration.shiftPollInterval)
                if !poster.physicalModifierFlags().contains(.maskShift) {
                    let waited = clock.now() - start
                    Log.mover.info("shift released after \(Int(waited * 1000)) ms; posting ⌥N")
                    return .released(afterSeconds: waited)
                }
            }
        }
        Log.mover.notice("posting ⌥N while physical Shift is still held")
        return .postedWhileHeld
    }

    public func move(_ window: WindowRef, toSpace n: Int) -> SpaceMoveResult {
        let frame: CGRect
        do { frame = try ax.frame(of: window) } catch let e as AXBackendError { return .failed(e) } catch { return .failed(.other(-1)) }
        guard let display = displays.display(for: frame) else { return .failed(.noValue) }

        // 1. Resolve the target.
        guard let target = spaces.userSpace(index: n, display: display.id) else {
            return .noSuchSpace(requested: n, available: spaces.spaceCount(display: display.id))
        }
        if target.id == spaces.activeSpace(display: display.id) { return .alreadyThere }
        if (try? ax.bool(.fullscreen, of: window)) == true { return .refusedFullscreen }
        if let g = transitions, !g.canSwitch(now: clock.now()) { return .transitionInFlight }
        guard let key = DigitKeys.keyCode(forDigit: n) else { return .noSuchSpace(requested: n, available: nil) }

        // 2. Grab point.
        guard let grab = findGrabPoint(for: window, frame: frame) else { return .noGrabPoint }

        // 3–7. Drag trick. Mouse-up and cursor restore always happen.
        let saved = poster.cursorLocation()
        poster.post(.mouseMove(grab))
        poster.post(.leftMouseDown(grab))
        poster.post(.leftMouseDragged(CGPoint(x: grab.x + 1, y: grab.y)))
        poster.post(.leftMouseDragged(grab))

        var mouseReleased = false
        func ensureMouseUp() {
            guard !mouseReleased else { return }
            mouseReleased = true
            poster.post(.leftMouseUp(grab))
            let curr = poster.cursorLocation()
            if curr != grab {
                poster.post(.leftMouseUp(curr))
            }
            poster.post(.warpCursor(saved))
        }
        defer { ensureMouseUp() }

        clock.sleep(configuration.pressDelay)
        let flags = switchFlags(forDesktop: n)
        lastShiftOutcome = waitForShiftRelease(posting: flags)
        poster.post(.keyDown(key, flags))
        poster.post(.keyUp(key, flags))
        transitions?.noteTransition(at: clock.now())

        let deadline = clock.now() + configuration.switchTimeout
        while spaces.activeSpace(display: display.id) != target.id {
            if clock.now() >= deadline {
                Log.mover.error("throw of \(window.description) to space \(n) timed out")
                return .timedOut
            }
            clock.sleep(configuration.pollInterval)
        }
        transitions?.noteTransition(at: clock.now())
        clock.sleep(configuration.settle)
        return .moved
    }
}
