import CoreGraphics
import Foundation

/// `WindowServerQuery` over a `FakeDesktop`: on-screen windows, front to back.
public final class FakeWindowServer: WindowServerQuery {
    let desk: FakeDesktop
    init(_ desk: FakeDesktop) { self.desk = desk }

    public func onscreenWindows() -> [OnscreenWindow] {
        desk.locked {
            desk.resolvePendingSwitch()
            return desk.zOrder.compactMap { r in
                guard let w = desk.windowTable[r], desk.onscreen(w) else { return nil }
                return OnscreenWindow(id: r.windowID, pid: r.pid, layer: w.layer, bounds: w.frame, alpha: w.alpha)
            }
        }
    }
}

/// `SpaceProvider` over a `FakeDesktop`. Minimized windows report no Spaces (assumed to match
/// `CGSCopySpacesForWindows`). With `desk.spacesUnavailable` it behaves like the SkyLight fallback.
public final class FakeSpaceProvider: SpaceProvider {
    let desk: FakeDesktop
    init(_ desk: FakeDesktop) { self.desk = desk }

    public var isNativeSpacesAvailable: Bool { desk.locked { !desk.spacesUnavailable } }

    public func activeSpace(display: DisplayID) -> SpaceID {
        desk.locked {
            if desk.spacesUnavailable { return SyntheticSpaces.id(for: display) }
            desk.resolvePendingSwitch()
            return desk.displayList.first { $0.info.id == display }?.active ?? SyntheticSpaces.id(for: display)
        }
    }

    public func spaces(display: DisplayID) -> [SpaceInfo] {
        desk.locked {
            if desk.spacesUnavailable { return SyntheticSpaces.spaces(display: display) }
            return desk.displayList.first { $0.info.id == display }?.spaces ?? SyntheticSpaces.spaces(display: display)
        }
    }

    public func spaces(of window: CGWindowID) -> [SpaceID] {
        desk.locked {
            guard !desk.spacesUnavailable,
                  let w = desk.windowTable.values.first(where: { $0.ref.windowID == window }), !w.minimized else { return [] }
            return [w.space]
        }
    }
}

public final class FakeDisplayProvider: DisplayProvider {
    let desk: FakeDesktop
    init(_ desk: FakeDesktop) { self.desk = desk }
    public func displays() -> [DisplayInfo] { desk.locked { desk.displayList.map(\.info) } }
}

public final class FakeAppProvider: AppProvider {
    let desk: FakeDesktop
    init(_ desk: FakeDesktop) { self.desk = desk }
    public func runningApplications() -> [AppInfo] {
        desk.locked { desk.appTable.values.map(\.info).sorted { $0.pid < $1.pid } }
    }
    public func application(pid: pid_t) -> AppInfo? { desk.locked { desk.appTable[pid]?.info } }
}

/// `EventPoster` over a `FakeDesktop` that also models the native drag trick: a left
/// mouse-down on a draggable titlebar spot grabs the window; a posted ⌥N switches to user
/// Space N of the cursor's display after `switchLatency` (unless a transition is animating,
/// in which case the key is silently dropped) and carries the grabbed window along.
public final class FakeEventPoster: EventPoster {
    let desk: FakeDesktop
    /// Called after every post (outside the lock). Stored on the desk.
    public var onPost: ((SyntheticEvent) -> Void)? {
        get { desk.locked { desk.posterOnPost } }
        set { desk.locked { desk.posterOnPost = newValue } }
    }
    init(_ desk: FakeDesktop) { self.desk = desk }

    public func cursorLocation() -> CGPoint { desk.locked { desk.cursor } }

    public func physicalModifierFlags() -> CGEventFlags {
        desk.locked {
            if let at = desk.heldModifiersReleaseAt, desk.clock.now() >= at { return [] }
            return desk.heldModifiers
        }
    }

    public func setCursor(_ p: CGPoint) { desk.locked { desk.cursor = p } }

    public func post(_ event: SyntheticEvent) {
        desk.locked {
            desk.postedEvents.append(event)
            switch event {
            case .mouseMove(let p), .warpCursor(let p):
                desk.cursor = p
            case .leftMouseDown(let p):
                desk.cursor = p
                desk.mouseIsDown = true
                if let hit = desk.hitTest(p), let w = hit.window, SpaceMover.isAcceptableGrab(hit, for: w) {
                    desk.grabbed = w
                }
            case .leftMouseUp(let p):
                desk.cursor = p
                desk.mouseIsDown = false
                desk.grabbed = nil
            case .keyDown(let code, let flags):
                guard desk.nativeSwitchEnabled,
                      flags.intersection(SpaceKeyFilter.relevantModifiers) == .maskAlternate,
                      let n = DigitKeys.digit(forKeyCode: code),
                      let info = DisplayGeometry.display(containing: desk.cursor, in: desk.displayList.map(\.info)),
                      let d = desk.displayList.first(where: { $0.info.id == info.id }),
                      let target = d.spaces.first(where: { $0.kind == .user && $0.index == n }),
                      target.id != d.active else { return }
                let now = desk.clock.now()
                if now < desk.transitionEnd || desk.pendingSwitch != nil {
                    desk.droppedSwitchCount += 1
                    return
                }
                desk.pendingSwitch = (info.id, target.id, now + desk.switchLatency, desk.mouseIsDown ? desk.grabbed : nil)
                desk.transitionEnd = now + desk.transitionDuration
            case .keyUp:
                break
            }
        }
        desk.locked { desk.posterOnPost }?(event)
    }
}

/// Settable `SystemStateQuery`.
public final class FakeSystemState: SystemStateQuery {
    public var isStageManagerEnabled = false
    public var displaysHaveSeparateSpaces = true
    public var isRectangleRunning = false
    public init() {}
}
