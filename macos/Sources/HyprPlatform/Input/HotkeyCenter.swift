import Carbon.HIToolbox
import Foundation

/// Global `<throw modifiers>`+1–9 ("throw window to Space N") and the toggle-float shortcut.
public protocol ThrowHotkeys: AnyObject {
    /// "Toggle floating ↔ tiling for the focused window" (⌥⇧F by default). Set before `start`.
    var onToggleFloat: (() -> Void)? { get set }
    /// True when the toggle-float shortcut could not be registered (taken by another app).
    var toggleFloatFailed: Bool { get }
    /// (Re-)registers the hotkeys for `bindings`, dropping the previous registrations first;
    /// returns the digits that failed to register (taken by another app).
    @discardableResult
    func start(bindings: KeyBindings, onThrow: @escaping (Int) -> Void) -> [Int]
    func stop()
}

public extension ThrowHotkeys {
    /// Registers the default shortcuts (⌥⇧1–9, ⌥⇧F).
    @discardableResult
    func start(onThrow: @escaping (Int) -> Void) -> [Int] { start(bindings: .defaults, onThrow: onThrow) }
}

/// Carbon `RegisterEventHotKey` implementation. Start/stop on the main thread.
public final class HotkeyCenter: ThrowHotkeys {
    /// Default throw modifiers: `optionKey | shiftKey`.
    public static let modifiers = KeyBindings.defaults.throwModifiers.carbon
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

    /// Every registration for `bindings`, in order: (hotkey id, virtual key code, Carbon modifiers).
    /// Pure data, so tests can check it.
    public static func registrations(for bindings: KeyBindings) -> [(id: UInt32, keyCode: UInt32, modifiers: UInt32)] {
        (1...9).compactMap { n in
            DigitKeys.keyCode(forDigit: n).map { (UInt32(n), UInt32($0), bindings.throwModifiers.carbon) }
        } + [(toggleFloatID, bindings.toggleFloat.keyCode, bindings.toggleFloat.modifiers.carbon)]
    }

    /// The default registrations: (hotkey id, virtual key code).
    public static var registrationTable: [(id: UInt32, keyCode: UInt32)] {
        registrations(for: .defaults).map { ($0.id, $0.keyCode) }
    }

    public init() {}

    @discardableResult
    public func start(bindings: KeyBindings, onThrow: @escaping (Int) -> Void) -> [Int] {
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
        for (id, code, modifiers) in Self.registrations(for: bindings) {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) }
            else if id == Self.toggleFloatID { toggleFloatFailed = true } else { failed.append(Int(id)) }
        }
        if !failed.isEmpty { Log.input.error("hotkeys \(bindings.throwModifiers.symbols)\(failed) failed to register") }
        if toggleFloatFailed { Log.input.error("hotkey \(bindings.toggleFloat.display) failed to register") }
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
