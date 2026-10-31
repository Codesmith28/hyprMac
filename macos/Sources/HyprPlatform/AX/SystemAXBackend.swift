import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Real `AXBackend`. Deliberately thin; all policy lives in testable code.
///
/// Window elements are cached per `WindowRef` from the latest `windows(pid:)` enumeration;
/// a cache miss re-enumerates that app once.
public final class SystemAXBackend: AXBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [WindowRef: AXUIElement] = [:]
    private let systemWide = AXUIElementCreateSystemWide()

    public init() {}

    public func isTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString // kAXTrustedCheckOptionPrompt
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public func setMessagingTimeout(pid: pid_t, seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), seconds)
    }

    public func windows(pid: pid_t) throws -> [WindowRef] {
        let app = AXUIElementCreateApplication(pid)
        let list: [AXUIElement] = try copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var refs: [WindowRef] = []
        lock.lock()
        cache = cache.filter { $0.key.pid != pid }
        for el in list {
            guard let wid = PrivateAPI.windowID(of: el) else { continue }
            let ref = WindowRef(pid: pid, windowID: wid)
            cache[ref] = el
            refs.append(ref)
        }
        lock.unlock()
        return refs
    }

    /// Resolves (and caches) the element for a ref. Exposed for the observer hub.
    public func element(for window: WindowRef) throws -> AXUIElement {
        lock.lock()
        if let el = cache[window] { lock.unlock(); return el }
        lock.unlock()
        _ = try windows(pid: window.pid)
        lock.lock(); defer { lock.unlock() }
        guard let el = cache[window] else { throw AXBackendError.unknownWindow }
        return el
    }

    public func facts(of window: WindowRef) throws -> WindowFacts {
        let el = try element(for: window)
        let role = (try? copy(el, kAXRoleAttribute) as? String) ?? "AXUnknown"
        let subrole = try? copy(el, kAXSubroleAttribute) as? String
        let title = try? copy(el, kAXTitleAttribute) as? String
        let frame = try self.frame(of: window)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
        let close = (try? copy(el, kAXCloseButtonAttribute)) != nil
        let app = NSRunningApplication(processIdentifier: window.pid)
        var minSize: CGSize?
        if let v = try? copy(el, "AXMinimumSize"), CFGetTypeID(v) == AXValueGetTypeID() {
            var s = CGSize.zero
            if AXValueGetValue(v as! AXValue, .cgSize, &s) { minSize = s }
        }
        return WindowFacts(
            role: role, subrole: subrole, title: title, frame: frame,
            isMinimized: (try? bool(.minimized, of: window)) ?? false,
            isFullscreen: (try? bool(.fullscreen, of: window)) ?? false,
            isResizable: settable.boolValue,
            isMain: (try? bool(.main, of: window)) ?? false,
            isFocused: (try? bool(.focused, of: window)) ?? false,
            bundleID: app?.bundleIdentifier,
            activationPolicy: ActivationPolicy(rawValue: app?.activationPolicy.rawValue ?? 0) ?? .regular,
            hasCloseButton: close, minSize: minSize)
    }

    public func frame(of window: WindowRef) throws -> CGRect {
        let el = try element(for: window)
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = try copy(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              let s = try copy(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { throw AXBackendError.noValue }
        return CGRect(origin: origin, size: size)
    }

    public func setPosition(_ origin: CGPoint, of window: WindowRef) throws {
        var o = origin
        guard let v = AXValueCreate(.cgPoint, &o) else { throw AXBackendError.noValue }
        try set(try element(for: window), kAXPositionAttribute, v)
    }

    public func setSize(_ size: CGSize, of window: WindowRef) throws {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { throw AXBackendError.noValue }
        try set(try element(for: window), kAXSizeAttribute, v)
    }

    public func bool(_ attribute: AXBoolAttribute, of window: WindowRef) throws -> Bool {
        (try copy(try element(for: window), attribute.rawValue) as? Bool) ?? false
    }

    public func setBool(_ attribute: AXBoolAttribute, _ value: Bool, of window: WindowRef) throws {
        try set(try element(for: window), attribute.rawValue, value as CFBoolean)
    }

    public func enhancedUserInterface(pid: pid_t) throws -> Bool {
        (try copy(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface") as? Bool) ?? false
    }

    public func setEnhancedUserInterface(_ value: Bool, pid: pid_t) throws {
        try set(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface", value as CFBoolean)
    }

    public func focusedApplication() throws -> pid_t? {
        guard let v = try copy(systemWide, kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(v as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    public func focusedWindow(pid: pid_t) throws -> WindowRef? {
        guard let v = try copy(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        let el = v as! AXUIElement
        guard let wid = PrivateAPI.windowID(of: el) else { return nil }
        let ref = WindowRef(pid: pid, windowID: wid)
        lock.lock(); cache[ref] = el; lock.unlock()
        return ref
    }

    public func element(at point: CGPoint) throws -> AXHit? {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        if err == .noValue { return nil }
        guard err == .success, let el = hit else { throw AXBackendError(err) }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let role = (try? copy(el, kAXRoleAttribute) as? String) ?? "AXUnknown"
        let subrole = try? copy(el, kAXSubroleAttribute) as? String
        var window: WindowRef?
        var isWindow = false
        if role == kAXWindowRole as String, let wid = PrivateAPI.windowID(of: el) {
            window = WindowRef(pid: pid, windowID: wid)
            isWindow = true
        } else if let w = try? copy(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID(),
                  let wid = PrivateAPI.windowID(of: w as! AXUIElement) {
            window = WindowRef(pid: pid, windowID: wid)
        }
        return AXHit(role: role, subrole: subrole, pid: pid, window: window, isWindowItself: isWindow)
    }

    // MARK: - primitives

    private func copy(_ el: AXUIElement, _ attr: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        switch err {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw AXBackendError(err)
        }
    }

    private func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(el, attr as CFString, value)
        guard err == .success else { throw AXBackendError(err) }
    }
}
