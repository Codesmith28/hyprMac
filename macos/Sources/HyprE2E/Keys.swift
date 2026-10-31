import CoreGraphics

/// Synthetic keyboard input, posted at the HID tap like a real keypress.
enum Keys {
    /// ANSI digit-row virtual keycodes.
    static let digit: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]

    static func post(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            pump(0.03)
        }
    }

    /// ⌥N (native "Switch to Desktop N") or ⌥⇧N (hyprMac throw).
    static func option(_ n: Int, shift: Bool = false) {
        guard let k = digit[n] else { return }
        post(k, flags: shift ? [.maskAlternate, .maskShift] : [.maskAlternate])
    }

    /// A human-like ⌥⇧N: ⌥ then ⇧ go down as separate flagsChanged events, the digit is
    /// pressed and released, and ⌥⇧ stay held `hold` seconds after the key-up before they are
    /// released (also on early exit). This is what a person's hands do; the single-event
    /// `option(_:shift:)` is not.
    static func throwHeld(_ n: Int, hold: Double = 0.3) {
        guard let k = digit[n] else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        func modifier(_ key: CGKeyCode, _ flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
            pump(0.03)
        }
        let option: CGKeyCode = 58, shift: CGKeyCode = 56   // kVK_Option, kVK_Shift
        modifier(option, .maskAlternate)
        modifier(shift, [.maskAlternate, .maskShift])
        defer {
            modifier(shift, .maskAlternate)
            modifier(option, [])
        }
        post(k, flags: [.maskAlternate, .maskShift])
        pump(hold)
    }

    /// Current cursor position (top-left global points).
    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Switch to user Space `n` and wait for the transition to finish.
    /// Waits for any running transition first: ⌥N during an animation is dropped.
    static func switchToSpace(_ n: Int) -> Bool {
        let spaces = Spaces.userSpaces
        guard n >= 1, n <= min(9, spaces.count) else { return false }
        Spaces.waitSettled()
        if Spaces.activeSpace() == spaces[n - 1] { return true }
        option(n)
        return Spaces.waitActive(spaces[n - 1], timeout: 5)
    }
}
