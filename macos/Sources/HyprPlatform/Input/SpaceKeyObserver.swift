import CoreGraphics
import Foundation

/// Listens (never intercepts) for ⌥1–9 so the coordinator knows a native Space switch was requested.
public protocol SpaceKeyObserving: AnyObject {
    /// Returns false when the tap couldn't be created (no Input Monitoring permission).
    @discardableResult
    func start(onSwitch: @escaping (Int) -> Void) -> Bool
    func stop()
}

/// Pure filtering for the Space-key tap.
public enum SpaceKeyFilter {
    /// Modifiers that must match exactly (caps lock and device bits are ignored).
    public static let relevantModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    /// The digit for an ⌥+digit keyDown with no other modifier, else nil. Autorepeats and
    /// hyprMac's own synthetic events are ignored.
    public static func digit(keyCode: CGKeyCode, flags: CGEventFlags, isAutorepeat: Bool = false,
                             sourceUserData: Int64 = 0) -> Int? {
        guard !isAutorepeat, !SyntheticEventMarker.isSynthetic(userData: sourceUserData) else { return nil }
        guard flags.intersection(relevantModifiers) == .maskAlternate else { return nil }
        return DigitKeys.digit(forKeyCode: keyCode)
    }

    /// The tap must be re-enabled after these.
    public static func shouldReenable(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }
}

/// Listen-only `CGEventTap` on keyDown at `.cgSessionEventTap`. Requires Input Monitoring.
public final class SpaceKeyObserver: SpaceKeyObserving {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var onSwitch: ((Int) -> Void)?

    public init() {}

    @discardableResult
    public func start(onSwitch: @escaping (Int) -> Void) -> Bool {
        stop()
        self.onSwitch = onSwitch
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SpaceKeyObserver>.fromOpaque(refcon).takeUnretainedValue()
            if SpaceKeyFilter.shouldReenable(type) {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .keyDown,
                      let n = SpaceKeyFilter.digit(
                        keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                        flags: event.flags,
                        isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        sourceUserData: event.getIntegerValueField(.eventSourceUserData)) {
                me.onSwitch?(n)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            Log.input.error("space-key event tap could not be created (Input Monitoring?)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        onSwitch = nil
    }

    deinit { stop() }
}
