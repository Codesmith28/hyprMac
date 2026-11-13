import Carbon.HIToolbox
import HyprPlatform
import os

/// Global ⌥⇧/ hotkey that opens the cheatsheet. Kept apart from `HotkeyCenter` so it works
/// even while tiling is paused or waiting for Accessibility permission.
final class ShortcutsHotkey {
    private static let signature: OSType = 0x4859_5048 // "HYPH"
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    fileprivate let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    @discardableResult
    func start(_ spec: KeySpec) -> Bool {
        stop()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr, id.signature == ShortcutsHotkey.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<ShortcutsHotkey>.fromOpaque(refcon).takeUnretainedValue().action()
            return noErr
        }, 1, &type, me, &handler)
        let st = RegisterEventHotKey(spec.keyCode, spec.modifiers.carbon,
                                     EventHotKeyID(signature: Self.signature, id: 1),
                                     GetApplicationEventTarget(), 0, &ref)
        if st != noErr {
            log.error("cheatsheet hotkey \(spec.display) failed to register")
            return false
        }
        return true
    }

    func stop() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { stop() }
}
