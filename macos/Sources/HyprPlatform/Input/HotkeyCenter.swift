import Carbon.HIToolbox
import Foundation

/// Global ⌥⇧1–9 ("throw window to Space N").
public protocol ThrowHotkeys: AnyObject {
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
            center.onThrow?(Int(id.id))
            return noErr
        }, 1, &spec, me, &handler)

        var failed: [Int] = []
        for n in 1...9 {
            guard let code = DigitKeys.keyCode(forDigit: n) else { continue }
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(UInt32(code), Self.modifiers, EventHotKeyID(signature: Self.signature, id: UInt32(n)),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(n) }
        }
        if !failed.isEmpty { Log.input.error("hotkeys ⌥⇧\(failed) failed to register") }
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
