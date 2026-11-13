import Carbon.HIToolbox
import Foundation

/// Global `<throw modifiers>`+1–9 ("throw window to Space N") and the toggle-float shortcut.
public protocol ThrowHotkeys: AnyObject {
    /// "Toggle floating ↔ tiling for the focused window" (⌥⇧F by default). Set before `start`.
    var onToggleFloat: (() -> Void)? { get set }
    /// Center the window (⌃⌥C by default). Set before `start`.
    var onCenterWindow: (() -> Void)? { get set }
    /// Change focus in the BSP tree in the given direction. Set before `start`.
    var onFocusDirection: ((Direction) -> Void)? { get set }
    /// Move window in the BSP tree in the given direction. Set before `start`.
    var onMoveDirection: ((Direction) -> Void)? { get set }
    /// An unbound-by-default action fired (resize, equalize, rotate, zoom, display move, pause). Set before `start`.
    var onAction: ((KeyAction) -> Void)? { get set }
    /// True when the toggle-float shortcut could not be registered (taken by another app).
    var toggleFloatFailed: Bool { get }
    /// (Re-)registers the hotkeys for `bindings`, dropping the previous registrations first;
    /// returns the digits that failed to register (taken by another app).
    @discardableResult
    func start(bindings: KeyBindings, onThrow: @escaping (Int) -> Void) -> [Int]
    func stop()
}

public extension ThrowHotkeys {
    /// Registers the default shortcuts (⌥⇧1–9, ⌥⇧F, ⌃⌥C, etc.).
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
    public var onCenterWindow: (() -> Void)?
    public var onFocusDirection: ((Direction) -> Void)?
    public var onMoveDirection: ((Direction) -> Void)?
    public var onAction: ((KeyAction) -> Void)?
    public private(set) var toggleFloatFailed = false
    public private(set) var currentBindings: KeyBindings?

    /// Hotkey id of ⌥⇧F (digits use their own number 1–9).
    public static let toggleFloatID: UInt32 = 100
    /// Hotkey id of Center Window (⌥⇧C).
    public static let centerWindowID: UInt32 = 200
    /// Base ID for focus direction shortcuts.
    public static let focusBaseID: UInt32 = 210
    /// Base ID for move direction shortcuts.
    public static let moveBaseID: UInt32 = 230

    /// Base ID for the unbound-by-default actions (`KeyAction.allCases` order).
    public static let actionBaseID: UInt32 = 250

    public static func hotkeyID(for action: KeyAction) -> UInt32 {
        actionBaseID + UInt32(KeyAction.allCases.firstIndex(of: action) ?? 0)
    }

    /// `kVK_ANSI_F`.
    public static let toggleFloatKeyCode = UInt32(kVK_ANSI_F)

    /// Every configurable chord (the throw digits excluded), labeled by its `keys.<name>`.
    /// Pure data, so tests and the macOS-shortcut conflict check can use it.
    public static func namedChords(for bindings: KeyBindings) -> [(id: UInt32, name: String, spec: KeySpec)] {
        var list: [(id: UInt32, name: String, spec: KeySpec)] = []
        list.append((toggleFloatID, "toggle_float", bindings.toggleFloat))
        list.append((centerWindowID, "center_window", bindings.centerWindow))
        for (i, item) in bindings.focusKeys.enumerated() {
            list.append((focusBaseID + UInt32(i), "focus_\(item.direction.rawValue)", item.spec))
        }
        for (i, item) in bindings.moveKeys.enumerated() {
            list.append((moveBaseID + UInt32(i), "move_\(item.direction.rawValue)", item.spec))
        }
        for action in KeyAction.allCases {
            if let spec = bindings.actionKeys[action] { list.append((hotkeyID(for: action), action.rawValue, spec)) }
        }
        return list
    }

    /// Every registration for `bindings`, in order: (hotkey id, virtual key code, Carbon modifiers).
    /// Chords in `bindings.suppressedIDs` are left out. Pure data, so tests can check it.
    public static func registrations(for bindings: KeyBindings) -> [(id: UInt32, keyCode: UInt32, modifiers: UInt32)] {
        var list: [(id: UInt32, keyCode: UInt32, modifiers: UInt32)] = []
        for n in 1...9 {
            if let kc = DigitKeys.keyCode(forDigit: n) {
                list.append((UInt32(n), UInt32(kc), bindings.throwModifiers.carbon))
            }
        }
        for c in namedChords(for: bindings) where !bindings.suppressedIDs.contains(c.id) {
            list.append((c.id, c.spec.keyCode, c.spec.modifiers.carbon))
        }
        return list
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
        self.currentBindings = bindings
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            if id.id == HotkeyCenter.toggleFloatID {
                center.onToggleFloat?()
            } else if id.id == HotkeyCenter.centerWindowID {
                center.onCenterWindow?()
            } else if id.id >= HotkeyCenter.focusBaseID && id.id < HotkeyCenter.focusBaseID + UInt32(center.currentBindings?.focusKeys.count ?? 0) {
                let idx = Int(id.id - HotkeyCenter.focusBaseID)
                if let direction = center.currentBindings?.focusKeys[idx].direction {
                    center.onFocusDirection?(direction)
                }
            } else if id.id >= HotkeyCenter.moveBaseID && id.id < HotkeyCenter.moveBaseID + UInt32(center.currentBindings?.moveKeys.count ?? 0) {
                let idx = Int(id.id - HotkeyCenter.moveBaseID)
                if let direction = center.currentBindings?.moveKeys[idx].direction {
                    center.onMoveDirection?(direction)
                }
            } else if id.id >= HotkeyCenter.actionBaseID && id.id < HotkeyCenter.actionBaseID + UInt32(KeyAction.allCases.count) {
                center.onAction?(KeyAction.allCases[Int(id.id - HotkeyCenter.actionBaseID)])
            } else {
                center.onThrow?(Int(id.id))
            }
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
