import AppKit
import CoreGraphics
import Foundation

/// Source of the current display layout (top-left global points).
public protocol DisplayProvider: AnyObject {
    func displays() -> [DisplayInfo]
}

extension DisplayProvider {
    public func display(id: DisplayID) -> DisplayInfo? { displays().first { $0.id == id } }
    public func display(containing point: CGPoint) -> DisplayInfo? { DisplayGeometry.display(containing: point, in: displays()) }
    public func display(for rect: CGRect) -> DisplayInfo? { DisplayGeometry.display(for: rect, in: displays()) }
}

/// Pure display geometry.
public enum DisplayGeometry {
    /// AppKit (bottom-left origin, y up) → top-left origin, y down:
    /// `y_top = primaryHeight - (y + height)`.
    public static func topLeft(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - (rect.origin.y + rect.height), width: rect.width, height: rect.height)
    }

    /// The display whose frame contains `point` (min edges inclusive, max edges exclusive).
    public static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// Largest intersection with `rect`; if nothing intersects, the display whose centre is
    /// nearest to the rect's centre.
    public static func display(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (DisplayInfo, CGFloat)?
        for d in displays {
            let i = d.frame.intersection(rect)
            guard !i.isNull, !i.isEmpty else { continue }
            let area = i.width * i.height
            if best == nil || area > best!.1 { best = (d, area) }
        }
        if let b = best { return b.0 }
        let c = rect.center
        return displays.min { distance2($0.frame.center, c) < distance2($1.frame.center, c) }
    }

    static func distance2(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

/// `NSScreen`-backed provider. `NSScreen` should be read on the main thread.
public final class SystemDisplayProvider: DisplayProvider {
    public init() {}

    public func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let h = primary.frame.height
        let main = CGMainDisplayID()
        return screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = DisplayID(n.uint32Value)
            return DisplayInfo(id: id,
                               frame: DisplayGeometry.topLeft(fromAppKit: s.frame, primaryHeight: h),
                               visibleFrame: DisplayGeometry.topLeft(fromAppKit: s.visibleFrame, primaryHeight: h),
                               isMain: id == main)
        }
    }
}
