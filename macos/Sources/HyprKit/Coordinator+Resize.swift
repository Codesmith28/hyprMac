import CoreGraphics
import Foundation
import HyprPlatform

/// Hyprland-style user resize and drag-to-move/swap.
/// - A drag that changed a tiled window's SIZE is adopted on mouse-up: the engine moves the adjacent
///   split ratios (`Engine.resize`) and the neighbours reflow.
/// - A drag of a tiled window onto another tile's region swaps them (`Engine.swap`); holding ⇧ on
///   release re-splits instead: the window lands on the side of that tile nearest the cursor
///   (`Engine.moveBeside`, see `DropZone`), which is how side-by-side becomes stacked and back.
/// - A drag of a floating window updates its recorded position (`firstSeenFrame`).
/// - Anything else snaps back through the normal reconcile. A user drag is never a fight: `handle`
///   returns before `noteFight` while dragging.
extension Coordinator {

    /// A size difference above this (points, per axis) from the last target counts as a resize.
    static let resizeTolerance: CGFloat = 2

    /// On `queue`, after the mouse button went up. Reads each touched window's live frame and
    /// adopts resizes or moves. Returns whether a plan was applied.
    @discardableResult
    func adoptUserResizes<S: Sequence>(_ windows: S) -> Bool where S.Element == HyprPlatform.WindowRef {
        dispatchPrecondition(condition: .onQueue(queue))
        var adopted = false
        for window in windows {
            guard let id = idByRef[window], let frame = try? deps.ax.frame(of: window) else { continue }
            if floatOverride[id] == true || lastStates[id] == .floating {
                firstSeenFrame[id] = frame
                if let bundle = bundleID(for: window) {
                    appStateStore.save(bundleID: bundle, state: SavedAppState(state: .floating, frame: frame))
                }
                continue
            }
            guard lastStates[id] == .tiled, let target = lastTargets[id] else { continue }
            let sizeChanged = abs(frame.width - target.width) > Self.resizeTolerance
                || abs(frame.height - target.height) > Self.resizeTolerance
            if sizeChanged {
                guard let plan = try? engine.resize(window: id, desired: frame) else { continue }
                activity += 1
                apply(plan)
                adopted = true
                if let bundle = bundleID(for: window) {
                    appStateStore.save(bundleID: bundle, state: SavedAppState(state: .tiled, frame: frame))
                }
                EventLog.shared.emit("user_resize", ["window": Int(window.windowID),
                                                     "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded())])
            } else if hypot(frame.midX - target.midX, frame.midY - target.midY) > 20 {
                guard let currentSpace = engine.space(of: id) else { continue }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let otherTiled = lastTargets.compactMap { otherId, rect -> (id: UInt64, rect: CGRect)? in
                    guard otherId != id,
                          lastStates[otherId] == .tiled,
                          engine.space(of: otherId) == currentSpace else { return nil }
                    return (otherId, rect)
                }
                let resplit = deps.poster.physicalModifierFlags().contains(.maskShift)
                let cursor = deps.poster.cursorLocation()
                let underCursor = resplit ? otherTiled.first(where: { $0.rect.contains(cursor) }) : nil
                let targetWindow = underCursor ?? otherTiled.first(where: { $0.rect.contains(center) })
                if let targetWindow {
                    if let underCursor, let side = DropZone.side(of: cursor, in: underCursor.rect) {
                        guard let plan = try? engine.moveBeside(window: id, target: underCursor.id, side: side) else { continue }
                        activity += 1
                        apply(plan)
                        EventLog.shared.emit("user_drag_resplit", ["window": Int(window.windowID),
                                                                   "target": Int(underCursor.id), "side": side.rawValue])
                    } else {
                        guard let plan = try? engine.swap(window: id, with: targetWindow.id) else { continue }
                        activity += 1
                        apply(plan)
                        EventLog.shared.emit("user_drag_move", ["window": Int(window.windowID), "target": Int(targetWindow.id)])
                    }
                    adopted = true
                }
            }
        }
        return adopted
    }
}
