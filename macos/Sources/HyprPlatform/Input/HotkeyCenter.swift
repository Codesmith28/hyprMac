import Carbon.HIToolbox
import Foundation

/// Global ⌥⇧1–9 ("throw window to Space N").
public protocol ThrowHotkeys: AnyObject {
    /// ⌥⇧F ("toggle floating ↔ tiling for the focused window"). Set before `start`.
    var onToggleFloat: (() -> Void)? { get set }
    /// True when ⌥⇧F could not be registered (taken by another app).
    var toggleFloatFailed: Bool { get }
    /// Registers the hotkeys; returns the digits that failed to register (taken by another app).
    @discardableResult
    func start(onThrow: @escaping (Int) -> Void) -> [Int]
    func stop()
}

/// Carbon `RegisterEventHotKey` implementation. Start/stop on the main thread.
public final class HotkeyCenter: ThrowHotkeys {
    /// `optionKey | shiftKey`.
    public static let modifiers = UInt32(optionKey | shiftKey)
    public static let signature: OSType = 0x4859_5052 // "HYPR"

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    fileprivate var onThrow: ((Int) -> Void)?
    public var onToggleFloat: (() -> Void)?
    public private(set) var toggleFloatFailed = false

    /// Hotkey id of ⌥⇧F (digits use their own number 1–9).
    public static let toggleFloatID: UInt32 = 100
    /// `kVK_ANSI_F`.
    public static let toggleFloatKeyCode = UInt32(kVK_ANSI_F)

    /// Every registration, in order: (hotkey id, virtual key code). Pure data, so tests can check it.
    public static var registrationTable: [(id: UInt32, keyCode: UInt32)] {
        (1...9).compactMap { n in DigitKeys.keyCode(forDigit: n).map { (UInt32(n), UInt32($0)) } }
            + [(toggleFloatID, toggleFloatKeyCode)]
    }

    public init() {}

    @discardableResult
    public func start(onThrow: @escaping (Int) -> Void) -> [Int] {
        stop()
        self.onThrow = onThrow
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            if id.id == HotkeyCenter.toggleFloatID { center.onToggleFloat?() } else { center.onThrow?(Int(id.id)) }
            return noErr
        }, 1, &spec, me, &handler)

        var failed: [Int] = []
        toggleFloatFailed = false
        for (id, code) in Self.registrationTable {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(code, Self.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) }
            else if id == Self.toggleFloatID { toggleFloatFailed = true } else { failed.append(Int(id)) }
        }
        if !failed.isEmpty { Log.input.error("hotkeys ⌥⇧\(failed) failed to register") }
        if toggleFloatFailed { Log.input.error("hotkey ⌥⇧F failed to register") }
        return failed
    }

    public func stop() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        if let h = handler { RemoveEventHandler(h) }
        handler = nil
        onThrow = nil
    }

    deinit { stop() }
}
