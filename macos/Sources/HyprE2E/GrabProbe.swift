import AppKit
import ApplicationServices

/// Read-only record of what the drag trick would hit on a window's titlebar: the same
/// candidate points as hyprMac's SpaceMover (8 pt below the top edge at 25 / 50 / 75 % of the
/// width and 80 pt from the left), hit-tested with AXUIElementCopyElementAtPosition.
/// Independent of HyprPlatform on purpose; it only reports, it never decides.
enum GrabProbe {
    struct Hit: CustomStringConvertible {
        let point: CGPoint
        let role: String
        /// The hit element is, or (walking up AXParent) belongs to, the window.
        let ownWindow: Bool
        var description: String { "\(role)\(ownWindow ? "" : "(other)")" }
    }

    static func candidates(for frame: CGRect) -> [CGPoint] {
        let y = frame.minY + 8
        return [0.25, 0.5, 0.75].map { CGPoint(x: frame.minX + frame.width * $0, y: y) }
            + [CGPoint(x: min(frame.minX + 80, frame.maxX - 1), y: y)]
    }

    static func hits(window id: CGWindowID, frame: CGRect) -> [Hit] {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        return candidates(for: frame).map { p in
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success, var cur = el else {
                return Hit(point: p, role: "none", ownWindow: false)
            }
            let role = string(cur, kAXRoleAttribute) ?? "?"
            for _ in 0..<8 {
                if Private.windowID(of: cur) == id, string(cur, kAXRoleAttribute) == kAXWindowRole {
                    return Hit(point: p, role: role, ownWindow: true)
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                cur = parent as! AXUIElement
            }
            return Hit(point: p, role: role, ownWindow: false)
        }
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
