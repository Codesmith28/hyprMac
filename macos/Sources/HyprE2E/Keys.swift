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
