import CoreGraphics
import Foundation

/// How sure discovery is that a window belongs to the snapshot's Space.
public enum SpaceMembership: Equatable, Sendable {
    /// SkyLight says the window is on this Space, or it is on screen on this display.
    case confirmed
    /// Ghost-state window (minimized / hidden / fullscreen) with no Space of its own on this
    /// display. The coordinator should only pass it to the engine if the engine doesn't
    /// already hold it on *another* Space (`hm_engine_space_of`).
    case inferred
}

public struct DiscoveredWindow: Equatable, Sendable {
    public var ref: WindowRef
    public var state: WindowState
    public var frame: CGRect
    public var minSize: CGSize?
    public var membership: SpaceMembership
    /// AX title at discovery time (nil when unreadable).
    public var title: String?
}

/// One (display, Space) as currently visible.
public struct DiscoverySnapshot: Equatable, Sendable {
    public var display: DisplayID
    public var space: SpaceID
    /// The display's `visibleFrame` (top-left points).
    public var usable: CGRect
    /// Focused window if it is in `windows`.
    public var focused: WindowRef?
    /// Front to back: on-screen windows in window-server order, then the rest.
    public var windows: [DiscoveredWindow]
    /// Windows whose AX calls kept failing with `cannotComplete` this round. They are NOT in
    /// `windows`; the coordinator must not treat them as closed (keep them, or re-run soon).
    public var unresolved: [WindowRef]
    /// Apps that didn't answer (window list failed or several windows timed out).
    public var unresponsivePids: [pid_t]
}

/// Builds a snapshot of one display + Space from the AX backend, window server and Space provider.
/// Never blocks for long: each app gets a messaging timeout and is abandoned after repeated
/// `cannotComplete`s.
public final class WindowDiscovery {
    public struct Configuration: Sendable {
        public var messagingTimeout: Float = 0.25
        /// Extra immediate attempts per AX call on `cannotComplete`.
        public var retries = 1
        /// After this many windows of one app fail, skip the rest of that app this round.
        public var maxFailedWindowsPerApp = 2
        public var ownBundleID: String? = WindowEligibility.ownBundleID
        public var floatBundleIDs = WindowEligibility.defaultFloatBundleIDs
        /// `rules.ignore`: apps that are never managed (never tiled, never moved).
        public var ignoreBundleIDs: Set<String> = []
        /// `rules.ignore_title`: windows whose first non-empty title matches are never managed.
        public var ignoreTitles = TitleMatcher()
        public init() {}
    }

    private let ax: AXBackend
    private let windowServer: WindowServerQuery
    private let spaces: SpaceProvider
    private let displays: DisplayProvider
    private let apps: AppProvider
    public var configuration: Configuration
    /// Sticky `ignore_title` decision per window (made once, from the first non-empty title).
    private var titleIgnored: [WindowRef: Bool] = [:]

    public init(ax: AXBackend, windowServer: WindowServerQuery, spaces: SpaceProvider,
                displays: DisplayProvider, apps: AppProvider, configuration: Configuration = Configuration()) {
        self.ax = ax
        self.windowServer = windowServer
        self.spaces = spaces
        self.displays = displays
        self.apps = apps
        self.configuration = configuration
    }

    public func snapshot(display displayID: DisplayID) -> DiscoverySnapshot? {
        let allDisplays = displays.displays()
        guard let display = allDisplays.first(where: { $0.id == displayID }) else { return nil }
        let space = spaces.activeSpace(display: displayID)
        let displaySpaces = spaces.spaces(display: displayID)
        let onscreenList = windowServer.onscreenWindows()
        var onscreen: [CGWindowID: (Int, OnscreenWindow)] = [:]
        for (i, w) in onscreenList.enumerated() where w.isOnscreen { onscreen[w.id] = (i, w) }

        var found: [DiscoveredWindow] = []
        var unresolved: [WindowRef] = []
        var unresponsive: [pid_t] = []

        for app in apps.runningApplications() where app.activationPolicy == .regular {
            if let own = configuration.ownBundleID, app.bundleID == own { continue }
            if let b = app.bundleID, configuration.ignoreBundleIDs.contains(b) { continue }
            ax.setMessagingTimeout(pid: app.pid, seconds: configuration.messagingTimeout)
            guard let refs = try? retrying({ try ax.windows(pid: app.pid) }) else {
                unresponsive.append(app.pid)
                continue
            }
            var failed = 0
            for (i, ref) in refs.enumerated() {
                if failed >= configuration.maxFailedWindowsPerApp {
                    unresolved.append(contentsOf: refs[i...])
                    unresponsive.append(app.pid)
                    break
                }
                let facts: WindowFacts
                do {
                    facts = try retrying { try ax.facts(of: ref) }
                } catch AXBackendError.cannotComplete {
                    failed += 1
                    unresolved.append(ref)
                    continue
                } catch {
                    continue // gone or unreadable: not a window we can manage
                }
                if titleIsIgnored(ref: ref, title: facts.title) { continue }
                let on = onscreen[ref.windowID]?.1
                guard let state = WindowEligibility.evaluate(
                    facts, onscreen: on, app: app, ownBundleID: configuration.ownBundleID,
                    floatBundleIDs: configuration.floatBundleIDs).state else { continue }
                guard DisplayGeometry.display(for: facts.frame, in: allDisplays)?.id == displayID else { continue }
                guard let membership = membership(ref: ref, state: state, isOnscreen: on != nil,
                                                  space: space, displaySpaces: displaySpaces) else { continue }
                found.append(DiscoveredWindow(ref: ref, state: state, frame: facts.frame,
                                              minSize: facts.minSize, membership: membership, title: facts.title))
            }
        }

        found = Self.dedupeTabs(found, isOnscreen: { onscreen[$0.windowID] != nil })
        found = Self.order(found, onscreenIndex: { onscreen[$0.windowID]?.0 })

        var focused: WindowRef?
        if let pid = try? ax.focusedApplication(), let ref = try? ax.focusedWindow(pid: pid),
           found.contains(where: { $0.ref == ref }) {
            focused = ref
        }
        return DiscoverySnapshot(display: displayID, space: space, usable: display.visibleFrame,
                                 focused: focused, windows: found, unresolved: unresolved,
                                 unresponsivePids: unresponsive)
    }

    /// `rules.ignore_title`, decided once per window from the first non-empty title it shows.
    private func titleIsIgnored(ref: WindowRef, title: String?) -> Bool {
        guard !configuration.ignoreTitles.isEmpty else { return false }
        if let decided = titleIgnored[ref] { return decided }
        guard let title, !title.isEmpty else { return false }
        if titleIgnored.count > 4096 { titleIgnored.removeAll() } // bounded; decisions are re-made lazily
        let hit = configuration.ignoreTitles.matches(title)
        titleIgnored[ref] = hit
        return hit
    }

    /// Forgets sticky title decisions (config reload with different patterns).
    public func resetTitleDecisions() { titleIgnored.removeAll() }

    private func membership(ref: WindowRef, state: WindowState, isOnscreen: Bool,
                            space: SpaceID, displaySpaces: [SpaceInfo]) -> SpaceMembership? {
        let ids = spaces.isNativeSpacesAvailable ? spaces.spaces(of: ref.windowID) : []
        if !ids.isEmpty {
            if ids.contains(space) { return .confirmed }
            // A fullscreen window lives on its own fullscreen Space of this display: keep its ghost.
            if state == .fullscreen,
               displaySpaces.contains(where: { $0.kind == .fullscreen && ids.contains($0.id) }) { return .inferred }
            return nil // on another Space
        }
        if state.isGhost { return .inferred }
        return isOnscreen ? .confirmed : nil
    }

    private func retrying<T>(_ body: () throws -> T) throws -> T {
        var attempt = 0
        while true {
            do { return try body() } catch AXBackendError.cannotComplete where attempt < configuration.retries {
                attempt += 1
            }
        }
    }

    /// Native tabs: several AX windows of one pid with an identical frame (±0.5 pt) where at
    /// most one is on screen collapse to the on-screen one (or the first, if none is).
    /// Ghost-state windows are left alone.
    public static func dedupeTabs(_ windows: [DiscoveredWindow], isOnscreen: (WindowRef) -> Bool) -> [DiscoveredWindow] {
        var drop = Set<WindowRef>()
        for (i, w) in windows.enumerated() where !w.state.isGhost && !drop.contains(w.ref) {
            let group = windows[i...].filter {
                !$0.state.isGhost && $0.ref.pid == w.ref.pid && $0.frame.isApproximately(w.frame, tolerance: 0.5)
            }
            guard group.count > 1 else { continue }
            let on = group.filter { isOnscreen($0.ref) }
            guard on.count <= 1 else { continue } // genuinely separate, overlapping windows
            let keep = on.first?.ref ?? group[0].ref
            for g in group where g.ref != keep { drop.insert(g.ref) }
        }
        return windows.filter { !drop.contains($0.ref) }
    }

    /// On-screen windows in window-server order (front to back), then the rest in input order.
    public static func order(_ windows: [DiscoveredWindow], onscreenIndex: (WindowRef) -> Int?) -> [DiscoveredWindow] {
        windows.enumerated().sorted { a, b in
            switch (onscreenIndex(a.element.ref), onscreenIndex(b.element.ref)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }
}
