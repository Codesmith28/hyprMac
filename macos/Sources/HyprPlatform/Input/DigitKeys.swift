import CoreGraphics

/// ANSI virtual keycodes of the number-row digits 1–9.
public enum DigitKeys {
    public static let keyCodes: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]

    public static func keyCode(forDigit n: Int) -> CGKeyCode? { keyCodes[n] }

    public static func digit(forKeyCode code: CGKeyCode) -> Int? {
        keyCodes.first { $0.value == code }?.key
    }
}
