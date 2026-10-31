import CoreGraphics
import Foundation
import HyprPlatform

/// Hyprland-style user resize. A drag that changed a tiled window's SIZE is adopted on mouse-up: the
/// engine moves the adjacent split ratios (`Engine.resize`) and the neighbours reflow. Anything else
/// the drag touched (a titlebar move, a size within `resizeTolerance` of its tile) snaps back through
/// the normal reconcile. A user resize is never a fight: `handle` returns before `noteFight` while dragging.
extension Coordinator {

    /// A size difference above this (points, per axis) from the last target counts as a resize.
    static let resizeTolerance: CGFloat = 2

    /// On `queue`, after the mouse button went up. Reads each touched window's live frame and
    /// adopts the ones whose size changed. Returns whether a plan was applied.
    @discardableResult
    func adoptUserResizes<S: Sequence>(_ windows: S) -> Bool where S.Element == HyprPlatform.WindowRef {
        dispatchPrecondition(condition: .onQueue(queue))
        var adopted = false
        for window in windows {
            guard let id = idByRef[window], lastStates[id] == .tiled, let target = lastTargets[id],
                  let frame = try? deps.ax.frame(of: window),
                  abs(frame.width - target.width) > Self.resizeTolerance
                    || abs(frame.height - target.height) > Self.resizeTolerance else { continue }
            guard let plan = try? engine.resize(window: id, desired: frame) else { continue }
            activity += 1
            apply(plan)
            adopted = true
            EventLog.shared.emit("user_resize", ["window": Int(window.windowID),
                                                 "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded())])
        }
        return adopted
    }
}
