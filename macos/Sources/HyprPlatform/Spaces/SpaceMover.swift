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
/// post the native ⌥N, wait for the Space change to land and settle, release.
///
/// `move` blocks for up to `switchTimeout + settle` (~1.5 s); call it on its own queue.
public final class SpaceMover {
    public struct Configuration: Sendable {
        /// Below the window's top edge (6–10 pt band).
        public var titlebarOffset: CGFloat = 8
        /// Offset of the "just right of the traffic lights" candidate.
        public var trafficLightsOffset: CGFloat = 80
        /// Pause between mouse-down and the key press.
        public var pressDelay: TimeInterval = 0.05
        public var pollInterval: TimeInterval = 0.02
        /// How long to wait for the active Space to become the target.
        public var switchTimeout: TimeInterval = 1.0
        /// Extra wait after the Space changed before releasing (animation still running).
        public var settle: TimeInterval = 0.4
        /// When no candidate at `titlebarOffset` is usable (e.g. the titlebar is all tab buttons,
        /// as in Ghostty with native tabs), also try the thin band at `thinBandOffset` below the
        /// top edge, where the window itself is hit. Needs live validation: a mouse-down this
        /// close to the edge could start a resize in some apps.
        public var thinBandFallback = true
        public var thinBandOffset: CGFloat = 3
        /// What to do if physical Shift is still held (the user is still on ⌥⇧N) before ⌥N.
        public var shiftRelease: ShiftReleasePolicy = .waitUpTo(0.3)
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
    public static let rejectedRoles: Set<String> = ["AXButton", "AXRadioButton", "AXTabGroup", "AXTextField",
                                                    "AXPopUpButton", "AXMenuButton", "AXToolbar"]
    /// Non-window roles accepted when they belong to the window (titlebar / tab-strip area).
    public static let acceptedAreaRoles: Set<String> = ["AXGroup", "AXUnknown"]

    private let ax: AXBackend
    private let spaces: SpaceProvider
    private let displays: DisplayProvider
    private let poster: EventPoster
    private let clock: TimeSource
    private let transitions: SpaceTransitionGuard?
    private let windowServer: WindowServerQuery?
    public var configuration: Configuration
    /// Shift handling of the most recent throw that reached the key press.
    public private(set) var lastShiftOutcome: ShiftOutcome?

    public init(ax: AXBackend, spaces: SpaceProvider, displays: DisplayProvider, poster: EventPoster,
                clock: TimeSource = SystemTimeSource(), transitions: SpaceTransitionGuard? = nil,
                windowServer: WindowServerQuery? = nil, configuration: Configuration = Configuration()) {
        self.windowServer = windowServer
        self.ax = ax
        self.spaces = spaces
        self.displays = displays
        self.poster = poster
        self.clock = clock
        self.transitions = transitions
        self.configuration = configuration
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

    /// A hit is a safe grab point if it is the window itself, or an `AXGroup`/`AXUnknown`
    /// area of that same window. Controls (tabs, buttons, fields, toolbars) are rejected.
    public static func isAcceptableGrab(_ hit: AXHit?, for window: WindowRef) -> Bool {
        guard let hit, hit.window == window, !rejectedRoles.contains(hit.role) else { return false }
        if hit.isWindowItself || hit.role == "AXWindow" { return true }
        return acceptedAreaRoles.contains(hit.role)
    }

    /// All candidates in search order: the normal band, then (if enabled) the thin band.
    public func candidates(for frame: CGRect) -> [CGPoint] {
        var pts = Self.grabCandidates(for: frame, titlebarOffset: configuration.titlebarOffset,
                                      trafficLightsOffset: configuration.trafficLightsOffset)
        if configuration.thinBandFallback {
            pts += Self.grabCandidates(for: frame, titlebarOffset: configuration.thinBandOffset,
                                       trafficLightsOffset: configuration.trafficLightsOffset)
        }
        return pts
    }

    /// The topmost on-screen layer-0 window containing `point` (window-server truth).
    public static func topmostWindow(at point: CGPoint, in onscreen: [OnscreenWindow]) -> CGWindowID? {
        onscreen.first { $0.layer == 0 && $0.isOnscreen && $0.bounds.contains(point) }?.id
    }

    /// First candidate whose AX hit is an acceptable grab for `window` AND where the window
    /// server agrees `window` is the topmost layer-0 window (guards against overlaps and AX
    /// resolving to the wrong window).
    public func findGrabPoint(for window: WindowRef, frame: CGRect) -> CGPoint? {
        let onscreen = windowServer?.onscreenWindows()
        for p in candidates(for: frame) {
            let hit = try? ax.element(at: p)
            guard Self.isAcceptableGrab(hit, for: window) else {
                Log.mover.debug("grab candidate \(p.debugDescription) rejected: \(hit?.role ?? "nil")")
                continue
            }
            if let list = onscreen, Self.topmostWindow(at: p, in: list) != window.windowID {
                Log.mover.debug("grab candidate \(p.debugDescription) rejected: another window is on top")
                continue
            }
            return p
        }
        return nil
    }

    /// Physical Shift still down (the user is still on ⌥⇧N) may stop macOS from recognising
    /// the synthetic ⌥N as "Switch to Desktop N". Wait per `shiftRelease`, and log the outcome.
    private func waitForShiftRelease() -> ShiftOutcome {
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
        defer {
            poster.post(.leftMouseUp(grab))
            poster.post(.warpCursor(saved))
        }
        clock.sleep(configuration.pressDelay)
        lastShiftOutcome = waitForShiftRelease()
        poster.post(.keyDown(key, .maskAlternate))
        poster.post(.keyUp(key, .maskAlternate))
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
