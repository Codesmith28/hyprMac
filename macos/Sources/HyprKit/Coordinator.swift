import AppKit
import CoreGraphics
import Foundation
import HyprPlatform
import os

/// The event coordinator: platform events → (debounced) reconcile → engine → executor.
///
/// All mutable state is confined to `queue` (one serial queue). Platform callbacks hop onto it;
/// the drag-trick mover runs on its own queue because it blocks for up to ~1.5 s.
public final class Coordinator: TilingController, GeometryExecutorDelegate {

    /// Everything the coordinator touches on the system, so tests can pass fakes.
    public struct Dependencies {
        public var ax: AXBackend
        public var windowServer: WindowServerQuery
        public var spaces: SpaceProvider
        public var displays: DisplayProvider
        public var apps: AppProvider
        public var systemState: SystemStateQuery
        public var poster: EventPoster
        public var hotkeys: ThrowHotkeys
        public var spaceKeys: SpaceKeyObserving
        public var clock: TimeSource
        /// Builds the platform event source; nil means "no live events" (tests drive `handle`).
        public var makeEvents: ((DispatchQueue, @escaping (PlatformEvent) -> Void) -> PlatformEvents)?
        /// Runs `block` on the main thread (tests run inline). Production must always hop
        /// asynchronously: delegate callbacks are delivered through it and may call back into
        /// the coordinator (e.g. read `isPaused`).
        public var onMain: (@escaping () -> Void) -> Void

        public init(ax: AXBackend, windowServer: WindowServerQuery, spaces: SpaceProvider,
                    displays: DisplayProvider, apps: AppProvider, systemState: SystemStateQuery,
                    poster: EventPoster, hotkeys: ThrowHotkeys, spaceKeys: SpaceKeyObserving,
                    clock: TimeSource,
                    makeEvents: ((DispatchQueue, @escaping (PlatformEvent) -> Void) -> PlatformEvents)?,
                    onMain: @escaping (@escaping () -> Void) -> Void) {
            self.ax = ax; self.windowServer = windowServer; self.spaces = spaces
            self.displays = displays; self.apps = apps; self.systemState = systemState
            self.poster = poster; self.hotkeys = hotkeys; self.spaceKeys = spaceKeys
            self.clock = clock; self.makeEvents = makeEvents; self.onMain = onMain
        }
    }

    public struct Tuning {
        /// Coalescing window for bursts of events.
        public var debounce: TimeInterval = 0.03
        /// Delay after the user releases the mouse before snapping windows back.
        public var dragSettle: TimeInterval = 0.12
        /// A window that resizes itself away from its tile this many times within
        /// `fightWindow` seconds is treated as floating (prevents feedback loops).
        public var fightLimit = 3
        public var fightWindow: TimeInterval = 10
        /// Moved/resized notifications arriving this long after a drag ended (AX lags behind
        /// the mouse) are the user's drag, not the app fighting its tile.
        public var dragGrace: TimeInterval = 0.5
        /// How often a throw that hit a still-animating Space transition is retried.
        public var throwRetries = 3
        public init() {}
    }

    // MARK: state (queue-confined)

    public weak var delegate: TilingControllerDelegate?
    public let queue = DispatchQueue(label: "dev.codesmith28.hyprmac.coordinator")
    private let moverQueue = DispatchQueue(label: "dev.codesmith28.hyprmac.mover")
    /// Delegate callbacks leave `queue` through here, so a delegate may synchronously call back
    /// into the coordinator (`isPaused` does `queue.sync`) without re-entering `queue`.
    private let deliveryQueue = DispatchQueue(label: "dev.codesmith28.hyprmac.delivery")
    private let deps: Dependencies
    private let tuning: Tuning
    private let logger = Logger(subsystem: "dev.codesmith28.hyprmac", category: "coordinator")

    private let engine: Engine
    private let configStore: ConfigStore
    private let identity = WindowIdentityMap()
    private let discovery: WindowDiscovery
    private let executor: GeometryExecutor
    private let mover: SpaceMover
    private let transitions = SpaceTransitionGuard(settle: 0.5)
    private var events: PlatformEvents?

    private var userPaused = false
    private var stageManagerPaused = false
    private var running = false
    private var dragging = false
    private var throwInFlight = false
    private var idsByPid: [pid_t: Set<UInt64>] = [:]
    private var fights: [UInt64: [TimeInterval]] = [:]
    private var uncooperative: Set<UInt64> = []
    private var lastTargets: [UInt64: CGRect] = [:]
    private var lastStates: [UInt64: Engine.TileState] = [:]
    private var unresolvedRetries = 0
    private var warnedRectangle = false
    /// Engine id per ref, as assigned during reconcile. Event handlers look ids up here instead
    /// of calling `identity.engineID(for:)`, which would re-assign generations for stale refs
    /// (a late report about a relaunched app's old window).
    private var idByRef: [HyprPlatform.WindowRef: UInt64] = [:]
    private var lastDragEnd: TimeInterval?
    private var reconcileGeneration = 0
    /// Timers scheduled on `queue` that haven't fired yet (for `testSettle`).
    private var outstandingTimers = 0
    /// Bumped by every state-changing step (for `testSettle`).
    private var activity = 0
    private var planCount = 0
    /// Engine Space ids shown on some display as of the last reconcile.
    private var activeSpaces: Set<UInt64> = []

    private let queueKey = DispatchSpecificKey<Bool>()

    /// Safe from any thread, including the coordinator queue itself.
    public var isPaused: Bool {
        if DispatchQueue.getSpecific(key: queueKey) == true { return userPaused || stageManagerPaused }
        return queue.sync { userPaused || stageManagerPaused }
    }

    public init(deps: Dependencies, configStore: ConfigStore, tuning: Tuning = Tuning()) {
        self.deps = deps
        self.tuning = tuning
        self.configStore = configStore
        self.engine = Engine()
        self.discovery = WindowDiscovery(ax: deps.ax, windowServer: deps.windowServer, spaces: deps.spaces,
                                         displays: deps.displays, apps: deps.apps)
        self.executor = GeometryExecutor(ax: deps.ax, clock: deps.clock)
        self.mover = SpaceMover(ax: deps.ax, spaces: deps.spaces, displays: deps.displays,
                                poster: deps.poster, clock: deps.clock, transitions: transitions)
        executor.delegate = self
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Production wiring.
    public static func live(configPath: URL) -> Coordinator {
        let deps = Dependencies(
            ax: SystemAXBackend(), windowServer: SystemWindowServerQuery(),
            spaces: SkyLightSpaceProvider(), displays: SystemDisplayProvider(), apps: SystemAppProvider(),
            systemState: SystemStateReader(), poster: SystemEventPoster(), hotkeys: HotkeyCenter(),
            spaceKeys: SpaceKeyObserver(), clock: SystemTimeSource(),
            makeEvents: { queue, handler in PlatformEvents(queue: queue, handler: handler) },
            onMain: { block in DispatchQueue.main.async(execute: block) })
        return Coordinator(deps: deps, configStore: ConfigStore(path: configPath))
    }

    // MARK: TilingController

    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            applyConfig(reload: false)
            checkSystemState()
        }
        if let make = deps.makeEvents {
            let ev = make(queue) { [weak self] e in self?.handle(e) }
            events = ev
            deps.onMain { ev.start() }
        }
        deps.onMain { [self] in
            let failed = deps.hotkeys.start { [weak self] n in self?.throwFocusedWindow(toSpace: n) }
            if !failed.isEmpty { logger.error("⌥⇧ hotkeys unavailable for digits \(failed)") }
            if !deps.spaceKeys.start(onSwitch: { [weak self] n in self?.spaceKeyPressed(n) }) {
                logger.error("space key observer unavailable; missing-space notices disabled")
            }
        }
        scheduleReconcile(after: 0)
    }

    public func stop() {
        let teardown = { [self] in
            deps.hotkeys.stop()
            deps.spaceKeys.stop()
            events?.stop()
        }
        // At quit an async hop may never run; on the main thread tear down right away.
        if Thread.isMainThread { teardown() } else { deps.onMain(teardown) }
        queue.sync {
            running = false
            reconcileGeneration += 1 // invalidates scheduled reconciles
        }
    }

    public func setPaused(_ paused: Bool, reason: String?) {
        queue.async { [self] in
            userPaused = paused
            if paused { EventLog.shared.emit("paused", ["reason": reason ?? "user"]) }
            stateChanged()
            if !paused { scheduleReconcile(after: 0) }
        }
    }

    public func retileAll() {
        queue.async { [self] in
            uncooperative.removeAll()
            fights.removeAll()
            scheduleReconcile(after: 0)
        }
    }

    public func reloadConfig() {
        queue.async { [self] in
            applyConfig(reload: true)
            scheduleReconcile(after: 0)
        }
    }

    // MARK: events

    /// Entry point for every platform event (on `queue`). Internal for tests.
    func handle(_ event: PlatformEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case let .window(kind, _, window):
            switch kind {
            case .destroyed:
                if let window { purge(window) } // C7: a closed minimized/hidden window leaves no ghost
                scheduleReconcile(after: tuning.debounce)
            case .moved, .resized:
                guard let window else { return }
                if dragging { return } // the user is moving it; settle on mouse-up
                if let frame = try? deps.ax.frame(of: window),
                   executor.echo.isEcho(window, observedFrame: frame, now: deps.clock.now()) {
                    return // our own write
                }
                if let end = lastDragEnd, deps.clock.now() - end <= tuning.dragGrace {
                    // Late notification from the user's drag: snap back, but it's no fight.
                } else {
                    noteFight(window)
                }
                scheduleReconcile(after: tuning.debounce)
            default:
                scheduleReconcile(after: tuning.debounce)
            }
        case let .appTerminated(pid):
            for id in idsByPid.removeValue(forKey: pid) ?? [] { forgetEngineWindow(id) }
            idByRef = idByRef.filter { $0.key.pid != pid }
            executor.forget(pid: pid)
            scheduleReconcile(after: tuning.debounce)
        case .activeSpaceChanged:
            transitions.noteTransition(at: deps.clock.now())
            checkSystemState()
            scheduleReconcile(after: tuning.debounce)
        case .screenParametersChanged:
            scheduleReconcile(after: 0.15) // displays settle a little after the notification
        case .userDragBegan:
            dragging = true
        case .userDragEnded:
            dragging = false
            lastDragEnd = deps.clock.now()
            scheduleReconcile(after: tuning.dragSettle)
        case .appLaunched, .appHidden, .appShown, .appActivated, .observerRegistrationFailed:
            scheduleReconcile(after: tuning.debounce)
        }
    }

    /// Drops every trace of a window that is known to be destroyed (C4, C7).
    private func purge(_ ref: HyprPlatform.WindowRef) {
        executor.forget(ref)
        guard let id = idByRef.removeValue(forKey: ref) else { return }
        idsByPid[ref.pid]?.remove(id)
        forgetEngineWindow(id)
    }

    private func forgetEngineWindow(_ id: UInt64) {
        engine.forget(window: id)
        identity.forget(engineID: id)
        uncooperative.remove(id)
        fights[id] = nil
        lastTargets[id] = nil
        lastStates[id] = nil
    }

    private func noteFight(_ window: HyprPlatform.WindowRef) {
        guard let id = idByRef[window], lastTargets[id] != nil else { return } // never tiled by us: not a fight
        let now = deps.clock.now()
        var list = (fights[id] ?? []).filter { now - $0 <= tuning.fightWindow }
        list.append(now)
        fights[id] = list
        if list.count >= tuning.fightLimit, !uncooperative.contains(id) {
            uncooperative.insert(id)
            logger.notice("window \(window.description) keeps resizing itself; floating it")
            EventLog.shared.emit("floated", ["window": Int(window.windowID), "reason": "fights"])
        }
    }

    // MARK: reconcile

    func scheduleReconcile(after delay: TimeInterval) {
        reconcileGeneration += 1
        let gen = reconcileGeneration
        schedule(after: delay) { [weak self] in
            guard let self, gen == self.reconcileGeneration else { return } // superseded
            self.reconcileNow()
        }
    }

    /// `asyncAfter` on `queue`, counted so tests can wait for quiescence.
    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        outstandingTimers += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.outstandingTimers -= 1
            work()
        }
    }

    /// Reconcile every display's active Space. Internal for tests.
    func reconcileNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running else { return }
        if !deps.ax.isTrusted(prompt: false) {
            running = false
            notify(.permissionLost)
            return
        }
        checkSystemState()
        guard !userPaused, !stageManagerPaused, !dragging, !throwInFlight else { return }
        activity += 1

        // C3: with "Displays have separate Spaces" off, every display reports the same Space id.
        // The engine keys trees by Space id, so give each display its own synthetic id then.
        let displays = deps.displays.displays()
        var activeCount: [UInt64: Int] = [:]
        for d in displays { activeCount[deps.spaces.activeSpace(display: d.id), default: 0] += 1 }
        activeSpaces.removeAll()
        for display in displays {
            guard var snap = discovery.snapshot(display: display.id) else { continue }
            if activeCount[snap.space, default: 0] > 1 {
                snap.space = Self.perDisplaySpaceID(space: snap.space, display: display.id)
            }
            activeSpaces.insert(snap.space)
            var entries: [Engine.WindowEntry] = []
            entries.reserveCapacity(snap.windows.count)
            var seen = Set<UInt64>()
            for w in snap.windows {
                let id = identity.engineID(for: w.ref)
                idByRef[w.ref] = id
                // A ghost (minimized/hidden/fullscreen) with no Space of its own must not be
                // pulled into this Space when the engine already holds it elsewhere.
                if w.membership == .inferred, let owner = engine.space(of: id), owner != snap.space { continue }
                idsByPid[w.ref.pid, default: []].insert(id)
                var state = Self.tileState(w.state)
                if state == .tiled, uncooperative.contains(id) { state = .floating }
                lastStates[id] = state
                seen.insert(id)
                entries.append(Engine.WindowEntry(id: id, state: state, frame: Self.sanitized(w.frame),
                                                  minSize: w.minSize ?? .zero))
            }
            // Windows whose AX calls failed this round keep their last state instead of being
            // deleted from the tree; try again shortly.
            for ref in snap.unresolved {
                guard let id = idByRef[ref], !seen.contains(id), engine.space(of: id) == snap.space,
                      let state = lastStates[id] else { continue }
                seen.insert(id)
                entries.append(Engine.WindowEntry(id: id, state: state))
            }
            // An app that didn't answer at all (hung, busy) keeps every window it had here.
            for pid in snap.unresponsivePids {
                for id in idsByPid[pid] ?? [] where !seen.contains(id) && engine.space(of: id) == snap.space {
                    guard let state = lastStates[id] else { continue }
                    seen.insert(id)
                    entries.append(Engine.WindowEntry(id: id, state: state))
                }
            }
            if snap.unresolved.isEmpty && snap.unresponsivePids.isEmpty { unresolvedRetries = 0 } else { retryUnresolved() }
            let focused = snap.focused.flatMap { idByRef[$0] }
            do {
                let plan = try engine.reconcile(display: display.id, space: snap.space, usable: snap.usable,
                                                focused: focused, windows: entries)
                apply(plan)
            } catch {
                logger.error("reconcile failed for space \(snap.space): \(String(describing: error))")
            }
        }
    }

    /// Bounded re-reconcile for windows that weren't AX-ready (late windows, busy apps).
    private func retryUnresolved() {
        guard unresolvedRetries < 4 else { return }
        unresolvedRetries += 1
        let delay = [0.1, 0.25, 0.5, 1.0][unresolvedRetries - 1]
        schedule(after: delay) { [weak self] in self?.reconcileNow() }
    }

    private func apply(_ plan: Engine.Plan) {
        activity += 1
        planCount += 1
        var placements: [(HyprPlatform.WindowRef, CGRect)] = []
        for p in plan.placements {
            guard let ref = identity.ref(forEngineID: p.id) else { continue }
            lastTargets[p.id] = p.frame
            placements.append((ref, p.frame))
        }
        executor.apply(revision: plan.revision, placements: placements)
        EventLog.shared.emit("plan_applied", ["space": plan.space, "revision": plan.revision,
                                              "count": placements.count])
    }

    // MARK: GeometryExecutorDelegate (called on the executor's delegate queue)

    public func geometryExecutor(_ executor: GeometryExecutor, didReport event: ExecutorEvent) {
        queue.async { [self] in
            activity += 1
            switch event {
            case let .minSizeDiscovered(ref, size):
                guard let id = idByRef[ref] else { return }
                // C2: an unchanged (e.g. unsatisfiable) minimum yields the same plan; re-applying
                // it would loop write → read-back → report forever.
                guard (try? engine.reportMinSizeChanged(window: id, size: size)) == true else { return }
                // C6: only re-plan a visible Space; others pick the minimum up on their next reconcile.
                if let space = engine.space(of: id), activeSpaces.contains(space),
                   let plan = try? engine.relayout(space: space) {
                    apply(plan)
                }
            case let .windowGone(ref):
                purge(ref) // C7
                scheduleReconcile(after: tuning.debounce)
            case let .mismatch(ref, _, _):
                // The app put itself somewhere else (snapped back, clamped). Count it as a fight
                // and re-plan; after `fightLimit` the window floats, which ends the loop.
                guard let id = idByRef[ref], !uncooperative.contains(id) else { return }
                noteFight(ref)
                scheduleReconcile(after: tuning.debounce)
            case .landed, .failed:
                break
            }
        }
    }

    // MARK: spaces & hotkeys

    /// ⌥N observed (the native shortcut performs the switch). Warn when Desktop N doesn't exist.
    func spaceKeyPressed(_ n: Int) {
        queue.async { [self] in
            guard let display = currentDisplay(), let count = deps.spaces.spaceCount(display: display) else { return }
            if n > count {
                EventLog.shared.emit("missing_space", ["n": n, "count": count])
                notify(.missingSpace(requested: n, count: count))
            } else if let target = deps.spaces.userSpace(index: n, display: display),
                      target.id != deps.spaces.activeSpace(display: display) {
                // macOS is about to animate; a throw posted during the animation would be dropped.
                transitions.noteTransition(at: deps.clock.now())
            }
        }
    }

    /// ⌥⇧N: throw the focused window to Desktop N with the drag trick (focus follows).
    func throwFocusedWindow(toSpace n: Int, attempt: Int = 0) {
        queue.async { [self] in
            guard !throwInFlight else { return }
            guard let pid = try? deps.ax.focusedApplication(),
                  let window = try? deps.ax.focusedWindow(pid: pid) else {
                EventLog.shared.emit("throw", ["n": n, "result": "noFocusedWindow"])
                return
            }
            activity += 1
            throwInFlight = true
            let sourceSpace = idByRef[window].flatMap { engine.space(of: $0) }
            moverQueue.async { [self] in
                let result = mover.move(window, toSpace: n)
                queue.async { [self] in
                    activity += 1
                    throwInFlight = false
                    EventLog.shared.emit("throw", ["n": n, "result": Self.name(result)])
                    switch result {
                    case .moved:
                        // Tile the window into the target Space now, then close the hole it left
                        // in the source Space (no longer visible, so no reconcile would reach it).
                        reconcileNow()
                        if let src = sourceSpace, let id = idByRef[window], engine.space(of: id) != src,
                           let plan = try? engine.relayout(space: src) {
                            apply(plan)
                        }
                    case .alreadyThere:
                        break
                    case .transitionInFlight:
                        // A ⌥N now would be silently dropped: retry once the animation settled.
                        if attempt < tuning.throwRetries {
                            let wait = max(0.05, transitions.remaining(now: deps.clock.now()))
                            schedule(after: wait) { [weak self] in self?.throwFocusedWindow(toSpace: n, attempt: attempt + 1) }
                        }
                    case let .noSuchSpace(_, available):
                        if let available { notify(.missingSpace(requested: n, count: available)) }
                    case .refusedFullscreen:
                        notify(.throwFailed(requested: n, reason: "Fullscreen windows can't be moved."))
                    case .noGrabPoint:
                        notify(.throwFailed(requested: n, reason: "This window has no titlebar area to grab."))
                    case .timedOut:
                        notify(.throwFailed(requested: n, reason: "macOS didn't switch Desktops in time. Is ⌥\(n) bound to “Switch to Desktop \(n)”?"))
                    case let .failed(e):
                        notify(.throwFailed(requested: n, reason: "Accessibility error: \(e)"))
                    }
                    scheduleReconcile(after: tuning.debounce)
                }
            }
        }
    }

    private func currentDisplay() -> DisplayID? {
        if let pid = try? deps.ax.focusedApplication(), let w = try? deps.ax.focusedWindow(pid: pid),
           let frame = try? deps.ax.frame(of: w), let d = deps.displays.display(for: frame) {
            return d.id
        }
        return deps.displays.displays().first(where: { $0.isMain })?.id ?? deps.displays.displays().first?.id
    }

    // MARK: config & system state

    private func applyConfig(reload: Bool) {
        switch configStore.load() {
        case let .loaded(c), let .missingUsedDefaults(c):
            do {
                try engine.setConfig(c)
                EventLog.shared.emit("config_loaded", ["inner": c.innerGap, "outer": c.outerGap])
                if reload { notify(.configLoaded) }
            } catch {
                EventLog.shared.emit("config_error", ["message": "engine rejected config"])
            }
        case let .failedKeptPrevious(message, _):
            logger.error("config error: \(message, privacy: .public)")
            EventLog.shared.emit("config_error", ["message": message])
            notify(.configError(message))
        }
    }

    private func checkSystemState() {
        let sm = deps.systemState.isStageManagerEnabled
        if sm != stageManagerPaused {
            stageManagerPaused = sm
            if sm {
                EventLog.shared.emit("paused", ["reason": "stage_manager"])
                notify(.stageManagerEnabled)
            }
            stateChanged()
        }
        if !warnedRectangle, deps.systemState.isRectangleRunning {
            warnedRectangle = true
            notify(.conflictingApp(name: "Rectangle"))
        }
    }

    /// Never calls the delegate from `queue` (or from inside a `queue.sync`): the callback is
    /// handed to `deliveryQueue` and from there to `onMain`.
    private func notify(_ notice: TilingNotice) {
        deliver { [weak self] in
            guard let self else { return }
            self.delegate?.tiling(self, didPost: notice)
        }
    }

    private func stateChanged() {
        deliver { [weak self] in
            guard let self else { return }
            self.delegate?.tilingStateChanged(self)
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        let onMain = deps.onMain
        deliveryQueue.async { onMain(block) }
    }

    // MARK: helpers

    static func tileState(_ s: WindowState) -> Engine.TileState {
        switch s {
        case .tiled: return .tiled
        case .floating: return .floating
        case .minimized: return .minimized
        case .fullscreen: return .fullscreen
        case .hidden: return .hidden
        }
    }

    /// The engine rejects non-finite rects; AX occasionally reports garbage for closing windows.
    /// Synthetic Space id for one display when several displays share a native Space id.
    /// The top two bits are set, so it collides neither with native ids nor with
    /// `SyntheticSpaces` (top bit only). Deterministic.
    static func perDisplaySpaceID(space: UInt64, display: UInt32) -> UInt64 {
        var x = space &* 0x9E37_79B9_7F4A_7C15 ^ (UInt64(display) &* 0xBF58_476D_1CE4_E5B9)
        x ^= x >> 31
        return 0xC000_0000_0000_0000 | (x & 0x3FFF_FFFF_FFFF_FFFF)
    }

    static func sanitized(_ r: CGRect) -> CGRect {
        let vals = [r.origin.x, r.origin.y, r.width, r.height]
        return vals.allSatisfy({ $0.isFinite }) ? r : .zero
    }

    static func name(_ r: SpaceMoveResult) -> String {
        switch r {
        case .moved: return "moved"
        case .alreadyThere: return "alreadyThere"
        case .noSuchSpace: return "noSuchSpace"
        case .refusedFullscreen: return "refusedFullscreen"
        case .noGrabPoint: return "noGrabPoint"
        case .timedOut: return "timedOut"
        case .transitionInFlight: return "transitionInFlight"
        case .failed: return "failed"
        }
    }

    // Test hooks
    func testStartWithoutInput() { queue.sync { running = true; applyConfig(reload: false); checkSystemState() } }
    func testUncooperative() -> Set<UInt64> { queue.sync { uncooperative } }
    /// The engine id last assigned to `ref` (nil if never reconciled). Doesn't touch generations.
    func testEngineID(_ ref: HyprPlatform.WindowRef) -> UInt64? { queue.sync { idByRef[ref] } }
    func testTiledCount(space: UInt64) -> Int { queue.sync { engine.tiledCount(space: space) } }
    func testSpaceOf(_ id: UInt64) -> UInt64? { queue.sync { engine.space(of: id) } }
    func testPlanCount() -> Int { queue.sync { planCount } }
    func testTrackedStateCount() -> (states: Int, targets: Int, ids: Int) {
        queue.sync { (lastStates.count, lastTargets.count, idByRef.count) }
    }
    func testActiveSpaces() -> Set<UInt64> { queue.sync { activeSpaces } }
    func testDump(space: UInt64) -> String { queue.sync { engine.debugDump(space: space) } }
    func testWaitForExecutor() -> Bool { executor.waitUntilIdle(timeout: 5) }

    /// Waits until nothing is left to do: no scheduled reconcile or retry, no throw in flight,
    /// the executor idle, and no state change during one full pass.
    func testSettle(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let before = queue.sync { activity }
            moverQueue.sync {}
            guard executor.waitUntilIdle(timeout: max(0.1, deadline.timeIntervalSinceNow)) else { return false }
            let quiet = queue.sync { outstandingTimers == 0 && !throwInFlight && activity == before }
            if quiet, executor.waitUntilIdle(timeout: 1), queue.sync(execute: { activity == before }) {
                deliveryQueue.sync {} // delegate callbacks posted so far have run (inline onMain)
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}
