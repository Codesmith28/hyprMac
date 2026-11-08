import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Pure helpers behind `SystemAXBackend`, kept separate so they can be unit-tested without
/// Accessibility permission (AXValues can be built and read without it).
public enum AXDecoding {
    /// Attributes fetched by `facts(of:)` in ONE `AXUIElementCopyMultipleAttributeValues` call,
    /// in this order.
    public static let factAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXMinimizedAttribute, "AXFullScreen", kAXMainAttribute, kAXFocusedAttribute, kAXCloseButtonAttribute,
        "AXMinimumSize",
    ]

    /// The window-level facts AX can answer (bundle id, activation policy and resizability are
    /// added by the backend).
    public struct DecodedFacts: Equatable {
        public var role: String
        public var subrole: String?
        public var title: String?
        public var frame: CGRect
        public var isMinimized: Bool
        public var isFullscreen: Bool
        public var isMain: Bool
        public var isFocused: Bool
        public var hasCloseButton: Bool
        public var minSize: CGSize?
    }

    /// The `AXError` carried by a per-slot error value (`AXValue` of type `.axError`), if any.
    public static func slotError(_ v: CFTypeRef?) -> AXError? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let value = v as! AXValue // type-checked above
        guard AXValueGetType(value) == .axError else { return nil }
        var err = AXError.success
        return AXValueGetValue(value, .axError, &err) ? err : nil
    }

    public static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    public static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func string(_ v: CFTypeRef?) -> String? {
        guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return v as? String
    }

    static func bool(_ v: CFTypeRef?) -> Bool {
        guard let v, CFGetTypeID(v) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    /// Decodes the values of `factAttributes`. Throws when a slot says the app stopped answering
    /// or the window died (so callers stop messaging it), or when the frame is missing.
    public static func decodeFacts(_ values: [CFTypeRef?]) throws -> DecodedFacts {
        guard values.count == factAttributes.count else { throw AXBackendError.noValue }
        for v in values {
            if let e = slotError(v), e == .cannotComplete || e == .invalidUIElement { throw AXBackendError(e) }
        }
        guard let origin = point(values[3]), let size = size(values[4]) else { throw AXBackendError.noValue }
        let close = values[9].map { slotError($0) == nil && CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
        return DecodedFacts(role: string(values[0]) ?? "AXUnknown", subrole: string(values[1]), title: string(values[2]),
                            frame: CGRect(origin: origin, size: size), isMinimized: bool(values[5]),
                            isFullscreen: bool(values[6]), isMain: bool(values[7]), isFocused: bool(values[8]),
                            hasCloseButton: close, minSize: self.size(values[10]))
    }

    /// Maps an `AXError`, turning `cannotComplete` into `invalidUIElement` when the owning
    /// process is gone (a cached element of a quit app reports "busy", not "gone").
    public static func classify(_ err: AXError, pidAlive: () -> Bool) -> AXBackendError {
        if err == .cannotComplete, !pidAlive() { return .invalidUIElement }
        return AXBackendError(err)
    }

    /// `kill(pid, 0)`: the process exists (EPERM still means it exists).
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Resolves the window a hit-tested element belongs to: the element itself if it is an
    /// `AXWindow`, else its `kAXWindow` attribute, else the first `AXWindow` among its
    /// `kAXParent` ancestors (at most `maxDepth` levels; stops at the application).
    /// Generic over the element type so it can be tested with plain values.
    public static func resolveWindow<E>(_ start: E, maxDepth: Int = 25, role: (E) -> String?,
                                        windowAttribute: (E) -> E?, parent: (E) -> E?,
                                        windowID: (E) -> CGWindowID?) -> (id: CGWindowID, isSelf: Bool)? {
        if role(start) == kAXWindowRole as String, let id = windowID(start) { return (id, true) }
        if let w = windowAttribute(start), (role(w) == nil || role(w) == kAXWindowRole as String), let id = windowID(w) { return (id, false) }
        var node = start
        for _ in 0..<maxDepth {
            guard let p = parent(node) else { return nil }
            let r = role(p)
            if r == kAXApplicationRole as String { return nil }
            if r == kAXWindowRole as String, let id = windowID(p) { return (id, false) }
            if let w = windowAttribute(p), (role(w) == nil || role(w) == kAXWindowRole as String), let id = windowID(w) { return (id, false) }
            node = p
        }
        return nil
    }
}
