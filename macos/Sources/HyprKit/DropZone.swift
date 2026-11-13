import CoreGraphics
import HyprPlatform

/// Where on a tile a ⇧-drop landed: the side to re-split towards, or nil in the middle (swap).
enum DropZone {
    /// Share of the half-width / half-height around the centre that still counts as "the middle".
    static let middle: CGFloat = 0.4

    static func side(of point: CGPoint, in rect: CGRect) -> Direction? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let nx = (point.x - rect.midX) / (rect.width / 2)
        let ny = (point.y - rect.midY) / (rect.height / 2)
        if abs(nx) < middle, abs(ny) < middle { return nil }
        if abs(nx) >= abs(ny) { return nx < 0 ? .left : .right }
        return ny < 0 ? .up : .down // top-left origin: smaller y is higher up
    }
}
