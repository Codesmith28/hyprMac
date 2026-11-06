import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Real `AXBackend`. Deliberately thin; all policy lives in testable code (`AXDecoding`).
///
/// Window elements are cached per `WindowRef` from the latest `windows(pid:)` enumeration;
/// a cache miss re-enumerates that app once.
///
/// **Messaging timeout:** `AXUIElementSetMessagingTimeout` only affects the element instance it
/// is set on, so a per-app value set on a throwaway application element does nothing. Setting
/// it on the *system-wide* element makes it the process-wide default for every element (verified
/// on macOS 27.2: a call to a hung app returns after ~0.25 s instead of ~1.5 s).
public final class SystemAXBackend: AXBackend, @unchecked Sendable {
    /// Default process-wide messaging timeout.
    public static let defaultMessagingTimeout: Float = 0.25

    private let lock = NSLock()
    private var cache: [WindowRef: AXUIElement] = [:]
    private let systemWide = AXUIElementCreateSystemWide()

    public init(messagingTimeout: Float = SystemAXBackend.defaultMessagingTimeout) {
        Self.applyGlobalMessagingTimeout(messagingTimeout)
    }

    /// Sets the process-wide AX messaging timeout (on the system-wide element).
    public static func applyGlobalMessagingTimeout(_ seconds: Float) {
        let err = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
        if err != .success { Log.ax.error("global AX messaging timeout not set: \(err.rawValue)") }
    }

    public func isTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString // kAXTrustedCheckOptionPrompt
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// No-op: the timeout is process-wide (set in `init`). Kept for the protocol and the fakes.
    public func setMessagingTimeout(pid: pid_t, seconds: Float) {}

    public func forget(pid: pid_t) {
        lock.lock(); cache = cache.filter { $0.key.pid != pid }; lock.unlock()
    }

    public func windows(pid: pid_t) throws -> [WindowRef] {
        let app = AXUIElementCreateApplication(pid)
        var list: [AXUIElement] = (try copy(app, kAXWindowsAttribute) as? [AnyObject] ?? [])
            .compactMap { Self.element($0 as CFTypeRef) }
        if list.isEmpty {
            if let focused = (try? copy(app, kAXFocusedWindowAttribute)).flatMap(Self.element) {
                list.append(focused)
            }
            if let main = (try? copy(app, kAXMainWindowAttribute)).flatMap(Self.element),
               !list.contains(where: { CFEqual($0, main) }) {
                list.append(main)
            }
        }
        var refs: [WindowRef] = []
        lock.lock()
        cache = cache.filter { $0.key.pid != pid }
        for el in list {
            guard let wid = PrivateAPI.windowID(of: el) else { continue }
            let ref = WindowRef(pid: pid, windowID: wid)
            if cache[ref] == nil {
                cache[ref] = el
                refs.append(ref)
            }
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
        lock.lock()
        if let el = cache[window] { lock.unlock(); return el }
        lock.unlock()
        _ = try? focusedWindow(pid: window.pid)
        lock.lock(); defer { lock.unlock() }
        guard let el = cache[window] else { throw AXBackendError.unknownWindow }
        return el
    }

    /// One `AXUIElementCopyMultipleAttributeValues` round trip for every AX fact, plus one
    /// `AXUIElementIsAttributeSettable` only if the app answered. `cannotComplete` propagates,
    /// so a hung app costs one timeout, not ten.
    public func facts(of window: WindowRef) throws -> WindowFacts {
        let el = try element(for: window)
        var raw: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, AXDecoding.factAttributes as CFArray,
                                                         AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard err == .success, let arr = raw as? [AnyObject] else { throw mapped(err == .success ? .noValue : err, window.pid) }
        let d = try AXDecoding.decodeFacts(arr.map { $0 as CFTypeRef })
        var settable: DarwinBoolean = false
        let serr = AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
        if serr == .cannotComplete || serr == .invalidUIElement { throw mapped(serr, window.pid) }
        let app = NSRunningApplication(processIdentifier: window.pid)
        return WindowFacts(
            role: d.role, subrole: d.subrole, title: d.title, frame: d.frame,
            isMinimized: d.isMinimized, isFullscreen: d.isFullscreen, isResizable: settable.boolValue,
            isMain: d.isMain, isFocused: d.isFocused, bundleID: app?.bundleIdentifier,
            activationPolicy: ActivationPolicy(rawValue: app?.activationPolicy.rawValue ?? 0) ?? .regular,
            hasCloseButton: d.hasCloseButton, minSize: d.minSize)
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
        AXDecoding.bool(try copy(try element(for: window), attribute.rawValue))
    }

    public func setBool(_ attribute: AXBoolAttribute, _ value: Bool, of window: WindowRef) throws {
        try set(try element(for: window), attribute.rawValue, value as CFBoolean)
    }

    public func raise(_ window: WindowRef) throws {
        let el = try element(for: window)
        AXUIElementPerformAction(el, "AXRaise" as CFString)
        _ = try? setBool(.main, true, of: window)
        _ = try? setBool(.focused, true, of: window)
    }

    public func enhancedUserInterface(pid: pid_t) throws -> Bool {
        AXDecoding.bool(try copy(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface"))
    }

    public func setEnhancedUserInterface(_ value: Bool, pid: pid_t) throws {
        try set(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface", value as CFBoolean)
    }

    public func trafficLightButtons(of window: WindowRef) -> (close: CGRect?, minimize: CGRect?, zoom: CGRect?) {
        guard let el = try? element(for: window) else { return (nil, nil, nil) }
        func frameOf(_ attr: String) -> CGRect? {
            guard let val = try? copy(el, attr), CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
            let btn = val as! AXUIElement
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard let p = try? copy(btn, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  AXValueGetValue(p as! AXValue, .cgPoint, &pos),
                  let s = try? copy(btn, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: pos, size: size)
        }
        let close = frameOf(kAXCloseButtonAttribute)
        let min = frameOf("AXMinimizeButton")
        let zoom = frameOf("AXFullScreenButton") ?? frameOf("AXZoomButton")
        return (close, min, zoom)
    }

    public func focusedApplication() throws -> pid_t? {
        guard let v = try copy(systemWide, kAXFocusedApplicationAttribute),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(v as! AXUIElement, &pid) == .success else { return nil } // type-checked above
        return pid
    }

    public func focusedWindow(pid: pid_t) throws -> WindowRef? {
        let app = AXUIElementCreateApplication(pid)
        let el = (try? copy(app, kAXFocusedWindowAttribute)).flatMap(Self.element)
            ?? (try? copy(app, kAXMainWindowAttribute)).flatMap(Self.element)
        guard let el, let wid = PrivateAPI.windowID(of: el) else { return nil }
        let ref = WindowRef(pid: pid, windowID: wid)
        lock.lock(); cache[ref] = el; lock.unlock()
        return ref
    }

    /// Hit test. The owning window is resolved with `AXDecoding.resolveWindow`: the element
    /// itself, its `kAXWindow`, or the first `AXWindow` among up to 6 `kAXParent`s (custom
    /// titlebars such as Ghostty's are `AXGroup`s without `kAXWindow`). Callers cross-check the
    /// result against the window server (see `SpaceMover`).
    public func element(at point: CGPoint) throws -> AXHit? {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        if err == .noValue { return nil }
        guard err == .success, let el = hit else { throw AXBackendError(err) }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let role = (try? copy(el, kAXRoleAttribute)).flatMap { AXDecoding.string($0) } ?? "AXUnknown"
        let subrole = (try? copy(el, kAXSubroleAttribute)).flatMap { AXDecoding.string($0) }
        let resolved = AXDecoding.resolveWindow(
            el,
            maxDepth: 25,
            role: { [self] e in (try? copy(e, kAXRoleAttribute)).flatMap { AXDecoding.string($0) } },
            windowAttribute: { [self] e in Self.element((try? copy(e, kAXWindowAttribute)) ?? nil) },
            parent: { [self] e in Self.element((try? copy(e, kAXParentAttribute)) ?? nil) },
            windowID: { PrivateAPI.windowID(of: $0) })
        return AXHit(role: role, subrole: subrole, pid: pid,
                     window: resolved.map { WindowRef(pid: pid, windowID: $0.id) },
                     isWindowItself: resolved?.isSelf ?? false)
    }

    // MARK: - primitives

    private static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement) // type-checked above
    }

    private func mapped(_ err: AXError, _ pid: pid_t) -> AXBackendError {
        AXDecoding.classify(err, pidAlive: { AXDecoding.isAlive(pid) })
    }

    private func pid(of el: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return pid
    }

    private func copy(_ el: AXUIElement, _ attr: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        switch err {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw mapped(err, pid(of: el))
        }
    }

    private func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(el, attr as CFString, value)
        guard err == .success else { throw mapped(err, pid(of: el)) }
    }
}
