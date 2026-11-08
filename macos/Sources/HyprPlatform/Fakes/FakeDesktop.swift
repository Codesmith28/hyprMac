import CoreGraphics
import Foundation

/// A titlebar area of a fake window that hit-tests as `role`: `from`/`to` are fractions of the
/// width, `top`/`bottom` points below the window's top edge (the titlebar is 28 pt).
/// `resolvesWindow: false` models an element whose owning window AX can't resolve.
public struct FakeTitlebarRegion: Equatable, Sendable {
    public var from: CGFloat
    public var to: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    public var role: String
    public var resolvesWindow: Bool
    public init(from: CGFloat, to: CGFloat, top: CGFloat = 0, bottom: CGFloat = 28, role: String,
                resolvesWindow: Bool = true) {
        self.from = from
        self.to = to
        self.top = top
        self.bottom = bottom
        self.role = role
        self.resolvesWindow = resolvesWindow
    }
}

/// Per-window quirk injection.
public struct FakeWindowQuirks: Equatable, Sendable {
    /// Setting a smaller size clamps to this.
    public var minSize: CGSize?
    /// Report `minSize` through `facts` (most apps don't).
    public var exposesMinSize = false
    /// Moves/resizes are clamped to the display's visible frame (needs size→position→size).
    public var clampToDisplay = false
    /// The first K AX calls on this window fail with `cannotComplete`.
    public var notReadyCalls = 0
    /// The window closes on the first write (`invalidUIElement`).
    public var closesOnWrite = false
    /// The app reverts to its previous size right after a resize.
    public var snapsBack = false
    /// Titlebar hit-test regions (e.g. a tab `AXRadioButton`); elsewhere the titlebar is the window.
    public var titlebarRegions: [FakeTitlebarRegion] = []
    /// Real macOS: a minimized standard window reports subrole "AXDialog" (observed on macOS 26/27).
    public var minimizedReportsDialog = true
    public init() {}
}

/// Every AX call the fake backend received, in order.
public enum FakeAXCall: Equatable, Sendable {
    case setMessagingTimeout(pid_t, Float)
    case windows(pid_t)
    case facts(WindowRef)
    case frame(WindowRef)
    case setPosition(WindowRef, CGPoint)
    case setSize(WindowRef, CGSize)
    case bool(AXBoolAttribute, WindowRef)
    case setBool(AXBoolAttribute, Bool, WindowRef)
    case raise(WindowRef)
    case enhancedUI(pid_t)
    case setEnhancedUI(pid_t, Bool)
    case focusedApplication
    case focusedWindow(pid_t)
    case elementAt(CGPoint)

    public var isWrite: Bool {
        switch self {
        case .setPosition, .setSize, .setBool, .setEnhancedUI, .raise: return true
        default: return false
        }
    }
}

/// An in-memory macOS desktop: displays, Spaces, apps and windows, with injectable quirks.
///
/// The facades (`ax`, `windowServer`, `spaces`, `displays`, `apps`, `poster`) implement the
/// platform protocols over this shared state, so they stay coherent (e.g. a throw via the
/// poster really moves the window to another Space). Thread-safe; AX delays (hung app,
/// enhanced UI) sleep for real *outside* the lock so per-pid isolation can be measured.
public final class FakeDesktop: @unchecked Sendable {
    struct Display {
        var info: DisplayInfo
        var spaces: [SpaceInfo]
        var active: SpaceID
    }

    struct App {
        var info: AppInfo
        var enhancedUI = false
        var hung = false
        var hangDuration: TimeInterval = 5
        /// Like the real backend's process-wide default (0.25 s).
        var messagingTimeout: Float = 0.25
        var euiSlowDelay: TimeInterval = 0.03
        var euiInaccuracy: CGFloat = 13
    }

    struct Window {
        var ref: WindowRef
        var role: String
        var subrole: String?
        var title: String?
        var frame: CGRect
        var minimized = false
        var fullscreen = false
        var resizable: Bool
        var hasCloseButton: Bool
        var space: SpaceID
        var layer: Int
        var alpha: Double
        var tabGroup: Int?
        var selectedTab = true
        var quirks: FakeWindowQuirks
        var beforeFullscreen: (space: SpaceID, frame: CGRect)?
        /// Mid fullscreen animation: AX doesn't list the window and the window server has no Space for it.
        var inTransition = false
    }

    public let clock: FakeClock
    /// Used for AX delays (hung apps, enhanced UI). Defaults to a real sleep.
    public var sleeper: (TimeInterval) -> Void
    /// Receives `PlatformEvent`s for mutations (window created, AX moves, space changes, ...).
    public var eventHandler: ((PlatformEvent) -> Void)?

    let lock = NSRecursiveLock()
    var displayList: [Display] = []
    var appTable: [pid_t: App] = [:]
    var windowTable: [WindowRef: Window] = [:]
    /// Front to back.
    var zOrder: [WindowRef] = []
    var focusedPid: pid_t?
    var focusedRef: WindowRef?
    var callLog: [FakeAXCall] = []
    var nextSpaceID: SpaceID = 1
    var nextTabGroup = 1
    var pendingEvents: [PlatformEvent] = []
    var emitted: [PlatformEvent] = []
    var depth = 0

    // Input / native Space switching.
    var cursor = CGPoint.zero
    var grabbed: WindowRef?
    var mouseIsDown = false
    var postedEvents: [SyntheticEvent] = []
    var pendingSwitch: (display: DisplayID, target: SpaceID, at: TimeInterval, carry: WindowRef?)?
    var transitionEnd: TimeInterval = -.infinity
    var droppedSwitchCount = 0
    var forgottenPidList: [pid_t] = []
    /// Physically held modifiers, released at `heldModifiersReleaseAt` (fake clock), if set.
    var heldModifiers: CGEventFlags = []
    var heldModifiersReleaseAt: TimeInterval?

    /// Simulate missing SkyLight symbols (synthetic Spaces, no window→Space info).
    public var spacesUnavailable = false
    /// Posted ⌥N switches Spaces (after `switchLatency`). Off = the switch never happens.
    public var nativeSwitchEnabled = true
    /// The modifiers of the native "Switch to Desktop N" shortcut (⌥ by default; ⌃ = `.maskControl`).
    public var nativeSwitchFlags: CGEventFlags = .maskAlternate
    public var switchLatency: TimeInterval = 0.35
    /// A ⌥N posted while a transition is animating is silently dropped (verified on 27.2).
    public var transitionDuration: TimeInterval = 0.5

    public init(clock: FakeClock = FakeClock(), sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: facades

    // Facades hold the desk strongly; the desk builds them on demand (no retain cycle).
    // Their settable state (`trusted`, `hitTestOverride`, `onPost`) lives on the desk.
    public var ax: FakeAXBackend { FakeAXBackend(self) }
    public var windowServer: FakeWindowServer { FakeWindowServer(self) }
    public var spaces: FakeSpaceProvider { FakeSpaceProvider(self) }
    public var displays: FakeDisplayProvider { FakeDisplayProvider(self) }
    public var apps: FakeAppProvider { FakeAppProvider(self) }
    public var poster: FakeEventPoster { FakeEventPoster(self) }

    var axTrusted = true
    var axHitTestOverride: ((CGPoint) -> AXHit?)?
    var axFocusedApplicationOverride: (() -> pid_t?)?
    var axFocusedWindowOverride: ((pid_t) -> WindowRef?)?
    var posterOnPost: ((SyntheticEvent) -> Void)?

    // MARK: locking / events

    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        depth += 1
        defer {
            depth -= 1
            let outermost = depth == 0
            lock.unlock()
            if outermost { flush() }
        }
        return try body()
    }

    func emit(_ e: PlatformEvent) { pendingEvents.append(e) }

    private func flush() {
        lock.lock()
        let events = pendingEvents
        pendingEvents.removeAll()
        emitted.append(contentsOf: events)
        let handler = eventHandler
        lock.unlock()
        for e in events { handler?(e) }
    }

    // MARK: building the world

    /// Adds a display with `userSpaces` user Spaces; the first is active. Returns the Space ids.
    @discardableResult
    public func addDisplay(_ id: DisplayID, frame: CGRect, visibleFrame: CGRect? = nil, isMain: Bool = false,
                           userSpaces: Int = 1) -> [SpaceID] {
        locked {
            let vf = visibleFrame ?? CGRect(x: frame.minX, y: frame.minY + 25, width: frame.width, height: frame.height - 25)
            var list: [SpaceInfo] = []
            for i in 1...max(1, userSpaces) {
                list.append(SpaceInfo(id: nextSpaceID, display: id, kind: .user, index: i))
                nextSpaceID += 1
            }
            displayList.append(Display(info: DisplayInfo(id: id, frame: frame, visibleFrame: vf, isMain: isMain),
                                       spaces: list, active: list[0].id))
            return list.map(\.id)
        }
    }

    /// Inserts a raw Space (e.g. to model non-contiguous ids). Returns its id.
    @discardableResult
    public func addSpace(display: DisplayID, id: SpaceID? = nil, kind: SpaceKind = .user) -> SpaceID {
        locked {
            guard let d = displayList.firstIndex(where: { $0.info.id == display }) else { return 0 }
            let sid = id ?? nextSpaceID
            nextSpaceID = max(nextSpaceID, sid + 1)
            displayList[d].spaces.append(SpaceInfo(id: sid, display: display, kind: kind, index: nil))
            reindex(d)
            return sid
        }
    }

    public func removeSpace(_ id: SpaceID) {
        locked {
            for d in displayList.indices {
                displayList[d].spaces.removeAll { $0.id == id }
                reindex(d)
            }
        }
    }

    private func reindex(_ d: Int) {
        var n = 0
        for i in displayList[d].spaces.indices where displayList[d].spaces[i].kind == .user {
            n += 1
            displayList[d].spaces[i].index = n
        }
        for i in displayList[d].spaces.indices where displayList[d].spaces[i].kind != .user {
            displayList[d].spaces[i].index = nil
        }
    }

    public func addApp(pid: pid_t, bundleID: String?, name: String? = nil, policy: ActivationPolicy = .regular) {
        locked {
            appTable[pid] = App(info: AppInfo(pid: pid, bundleID: bundleID, name: name, activationPolicy: policy))
            emit(.appLaunched(pid, bundleID: bundleID))
        }
    }

    /// Adds a window at the front. `space` defaults to the active Space of the display under the frame.
    @discardableResult
    public func addWindow(pid: pid_t, id: CGWindowID, frame: CGRect, role: String = "AXWindow",
                          subrole: String? = "AXStandardWindow", title: String? = nil, space: SpaceID? = nil,
                          resizable: Bool = true, hasCloseButton: Bool = true, layer: Int = 0, alpha: Double = 1,
                          quirks: FakeWindowQuirks = FakeWindowQuirks()) -> WindowRef {
        locked {
            let ref = WindowRef(pid: pid, windowID: id)
            let sid = space ?? displayFor(frame).map(\.active) ?? 0
            windowTable[ref] = Window(ref: ref, role: role, subrole: subrole, title: title, frame: frame,
                                      resizable: resizable, hasCloseButton: hasCloseButton, space: sid,
                                      layer: layer, alpha: alpha, quirks: quirks)
            zOrder.insert(ref, at: 0)
            emit(.window(.created, pid: pid, window: ref))
            return ref
        }
    }

    /// Native tabs: several AX windows with one frame; only `selected` is on screen.
    @discardableResult
    public func addTabs(pid: pid_t, ids: [CGWindowID], frame: CGRect, selected: Int = 0) -> [WindowRef] {
        let group = locked { () -> Int in nextTabGroup += 1; return nextTabGroup }
        let refs = ids.map { addWindow(pid: pid, id: $0, frame: frame) }
        locked {
            for (i, r) in refs.enumerated() {
                windowTable[r]?.tabGroup = group
                windowTable[r]?.selectedTab = i == selected
            }
        }
        return refs
    }

    // MARK: mutations

    public func updateQuirks(_ ref: WindowRef, _ change: (inout FakeWindowQuirks) -> Void) {
        locked { if var w = windowTable[ref] { change(&w.quirks); windowTable[ref] = w } }
    }

    /// Hung app: every AX call blocks for min(`duration`, messaging timeout) then fails `cannotComplete`.
    public func setHung(pid: pid_t, _ hung: Bool, duration: TimeInterval = 5) {
        locked { appTable[pid]?.hung = hung; appTable[pid]?.hangDuration = duration }
    }

    /// `AXEnhancedUserInterface` on: size sets take `slowDelay` and land `inaccuracy` pt short.
    public func setEnhancedUI(pid: pid_t, _ on: Bool, slowDelay: TimeInterval = 0.03, inaccuracy: CGFloat = 13) {
        locked {
            appTable[pid]?.enhancedUI = on
            appTable[pid]?.euiSlowDelay = slowDelay
            appTable[pid]?.euiInaccuracy = inaccuracy
        }
    }

    public func setMinimized(_ ref: WindowRef, _ value: Bool) {
        locked {
            guard windowTable[ref] != nil, windowTable[ref]!.minimized != value else { return }
            windowTable[ref]!.minimized = value
            emit(.window(value ? .miniaturized : .deminiaturized, pid: ref.pid, window: ref))
        }
    }

    public func setAppHidden(pid: pid_t, _ hidden: Bool) {
        locked {
            guard appTable[pid] != nil else { return }
            appTable[pid]!.info.isHidden = hidden
            emit(hidden ? .appHidden(pid) : .appShown(pid))
        }
    }

    /// Native fullscreen: the window moves to a new fullscreen Space (after its own) that becomes
    /// active; subrole stays standard and `AXFullScreen` reads true. Exiting reverses it.
    public func setFullscreen(_ ref: WindowRef, _ on: Bool) {
        locked {
            guard var w = windowTable[ref], w.fullscreen != on,
                  let d = displayList.firstIndex(where: { $0.spaces.contains { $0.id == w.space } }) else { return }
            if on {
                let fs = nextSpaceID
                nextSpaceID += 1
                let pos = (displayList[d].spaces.firstIndex { $0.id == w.space } ?? 0) + 1
                displayList[d].spaces.insert(SpaceInfo(id: fs, display: displayList[d].info.id, kind: .fullscreen, index: nil), at: pos)
                w.beforeFullscreen = (w.space, w.frame)
                w.space = fs
                w.frame = displayList[d].info.frame
                w.fullscreen = true
                displayList[d].active = fs
            } else if let before = w.beforeFullscreen {
                let fs = w.space
                displayList[d].spaces.removeAll { $0.id == fs }
                w.space = before.space
                w.frame = before.frame
                w.fullscreen = false
                w.beforeFullscreen = nil
                displayList[d].active = before.space
            }
            w.inTransition = false
            windowTable[ref] = w
            emit(.window(.resized, pid: ref.pid, window: ref))
            emit(.activeSpaceChanged)
        }
    }

    /// Real macOS, just before a window reports fullscreen: it drops out of its app's AX window list and
    /// belongs to no Space. `setFullscreen(_, true)` (or another call with `false`) ends it.
    public func setFullscreenTransition(_ ref: WindowRef, _ on: Bool) {
        locked { windowTable[ref]?.inTransition = on }
    }

    public func closeWindow(_ ref: WindowRef) {
        locked {
            guard windowTable.removeValue(forKey: ref) != nil else { return }
            zOrder.removeAll { $0 == ref }
            if focusedRef == ref { focusedRef = nil }
            emit(.window(.destroyed, pid: ref.pid, window: ref))
        }
    }

    public func terminate(pid: pid_t) {
        locked {
            appTable[pid] = nil
            for r in windowTable.keys where r.pid == pid { windowTable[r] = nil }
            zOrder.removeAll { $0.pid == pid }
            if focusedPid == pid { focusedPid = nil; focusedRef = nil }
            emit(.appTerminated(pid))
        }
    }

    /// Terminates `pid` and relaunches it as `newPid` with the SAME `CGWindowID`s and frames.
    @discardableResult
    public func relaunch(pid: pid_t, as newPid: pid_t) -> [WindowRef] {
        let (app, wins) = locked { () -> (App?, [Window]) in
            (appTable[pid], zOrder.filter { $0.pid == pid }.compactMap { windowTable[$0] })
        }
        terminate(pid: pid)
        guard let app else { return [] }
        addApp(pid: newPid, bundleID: app.info.bundleID, policy: app.info.activationPolicy)
        return wins.reversed().map {
            addWindow(pid: newPid, id: $0.ref.windowID, frame: $0.frame, role: $0.role, subrole: $0.subrole,
                      space: $0.space, resizable: $0.resizable, hasCloseButton: $0.hasCloseButton,
                      quirks: $0.quirks)
        }.reversed()
    }

    public func focus(_ ref: WindowRef) {
        locked {
            guard windowTable[ref] != nil else { return }
            focusedPid = ref.pid
            focusedRef = ref
            zOrder.removeAll { $0 == ref }
            zOrder.insert(ref, at: 0)
            emit(.appActivated(ref.pid))
            emit(.window(.focused, pid: ref.pid, window: ref))
        }
    }

    public func setActiveSpace(_ space: SpaceID, display: DisplayID) {
        locked {
            guard let d = displayList.firstIndex(where: { $0.info.id == display }) else { return }
            displayList[d].active = space
            emit(.activeSpaceChanged)
        }
    }

    public func moveWindow(_ ref: WindowRef, toSpace space: SpaceID) {
        locked { windowTable[ref]?.space = space }
    }

    public func setFrame(_ ref: WindowRef, _ frame: CGRect) {
        locked { windowTable[ref]?.frame = frame }
    }

    // MARK: inspection

    public func frame(of ref: WindowRef) -> CGRect? { locked { windowTable[ref]?.frame } }
    public func space(of ref: WindowRef) -> SpaceID? { locked { windowTable[ref]?.space } }
    public func isOnscreen(_ ref: WindowRef) -> Bool { locked { windowTable[ref].map(onscreen) ?? false } }
    public func enhancedUI(pid: pid_t) -> Bool { locked { appTable[pid]?.enhancedUI ?? false } }
    public func messagingTimeout(pid: pid_t) -> Float? { locked { appTable[pid]?.messagingTimeout } }
    public func activeSpaceRaw(display: DisplayID) -> SpaceID? {
        locked { resolvePendingSwitch(); return displayList.first { $0.info.id == display }?.active }
    }
    public var cursorPosition: CGPoint { locked { cursor } }
    public var axCalls: [FakeAXCall] { locked { callLog } }
    public func axCalls(for ref: WindowRef) -> [FakeAXCall] {
        locked { callLog.filter { $0.target == ref || ($0.pid == ref.pid && $0.target == nil) } }
    }
    public func clearAXCalls() { locked { callLog.removeAll() } }
    public var events: [PlatformEvent] { locked { emitted } }
    public func clearEvents() { locked { emitted.removeAll() } }
    public var posted: [SyntheticEvent] { locked { postedEvents } }
    public var droppedSwitches: Int { locked { droppedSwitchCount } }
    /// Pids passed to `ax.forget(pid:)`.
    public var forgottenPids: [pid_t] { locked { forgottenPidList } }

    /// The user physically holds `flags` until the fake clock reaches `releaseAt` (forever if nil).
    public func holdModifiers(_ flags: CGEventFlags, releaseAt: TimeInterval? = nil) {
        locked { heldModifiers = flags; heldModifiersReleaseAt = releaseAt }
    }

    // MARK: internals (call with lock held)

    func displayFor(_ rect: CGRect) -> Display? {
        guard let info = DisplayGeometry.display(for: rect, in: displayList.map(\.info)) else { return nil }
        return displayList.first { $0.info.id == info.id }
    }

    func displayOwning(space: SpaceID) -> Display? {
        displayList.first { $0.spaces.contains { $0.id == space } }
    }

    func onscreen(_ w: Window) -> Bool {
        guard !w.minimized, appTable[w.ref.pid]?.info.isHidden == false, w.selectedTab,
              let d = displayOwning(space: w.space) else { return false }
        return d.active == w.space
    }

    func resolvePendingSwitch() {
        guard let p = pendingSwitch, clock.now() >= p.at,
              let d = displayList.firstIndex(where: { $0.info.id == p.display }) else { return }
        pendingSwitch = nil
        displayList[d].active = p.target
        if let r = p.carry { windowTable[r]?.space = p.target }
        emit(.activeSpaceChanged)
    }
}

extension FakeAXCall {
    var target: WindowRef? {
        switch self {
        case .facts(let r), .frame(let r), .setPosition(let r, _), .setSize(let r, _), .bool(_, let r), .setBool(_, _, let r), .raise(let r):
            return r
        default: return nil
        }
    }

    var pid: pid_t? {
        switch self {
        case .setMessagingTimeout(let p, _), .windows(let p), .enhancedUI(let p), .setEnhancedUI(let p, _), .focusedWindow(let p):
            return p
        default: return target?.pid
        }
    }
}
