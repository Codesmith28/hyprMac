import CoreGraphics
import Foundation

/// Window-server view of on-screen windows (front to back).
public protocol WindowServerQuery: AnyObject {
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` — windows visible on the current
    /// Space(s) of every display, front to back.
    func onscreenWindows() -> [OnscreenWindow]
}

public final class SystemWindowServerQuery: WindowServerQuery {
    public init() {}

    public func onscreenWindows() -> [OnscreenWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return WindowListParser.parse(raw)
    }
}

/// Pure parser for `CGWindowListCopyWindowInfo` dictionaries.
public enum WindowListParser {
    public static func parse(_ raw: [[String: Any]]) -> [OnscreenWindow] {
        raw.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            var bounds = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
            }
            return OnscreenWindow(
                id: id, pid: pid,
                layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnscreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }
}
