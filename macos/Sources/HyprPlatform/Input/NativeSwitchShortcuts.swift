import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The user's native "Switch to Desktop N" shortcuts (`com.apple.symbolichotkeys`, ids 118–126).
public protocol NativeSwitchShortcuts: AnyObject {
    /// Modifiers of every ENABLED shortcut whose key is the digit key itself, by digit 1–9.
    func enabledModifiers() -> [Int: CGEventFlags]
}

public enum SymbolicHotkeys {
    /// "Switch to Desktop 1" is id 118, … Desktop 9 is 126.
    public static let firstDesktopID = 118
    public static let domain = "com.apple.symbolichotkeys"

    /// Pure parser of the `AppleSymbolicHotKeys` dictionary. `parameters` is
    /// `(ascii, key code, modifier mask)`; the mask uses the `CGEventFlags` bit values
    /// (524288 = ⌥, 262144 = ⌃, 131072 = ⇧, 1048576 = ⌘). Disabled entries, entries bound to a
    /// key other than the digit's own, and malformed ones are skipped.
    public static func parse(_ all: [String: Any]) -> [Int: CGEventFlags] {
        var out: [Int: CGEventFlags] = [:]
        for n in 1...9 {
            guard let entry = all[String(firstDesktopID + n - 1)] as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let key = (params[1] as? NSNumber)?.intValue,
                  let mask = (params[2] as? NSNumber)?.uint64Value,
                  key == DigitKeys.keyCode(forDigit: n).map({ Int($0) }) else { continue }
            let flags = CGEventFlags(rawValue: mask).intersection(SpaceKeyFilter.relevantModifiers)
                .subtracting(.maskSecondaryFn)
            guard !flags.isEmpty else { continue }
            out[n] = flags
        }
        return out
    }
}

/// Reads the preferences read-only on every call, so a change in System Settings applies at once.
public final class SystemNativeSwitchShortcuts: NativeSwitchShortcuts {
    public init() {}

    public func enabledModifiers() -> [Int: CGEventFlags] {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, SymbolicHotkeys.domain as CFString)
        return SymbolicHotkeys.parse(value as? [String: Any] ?? [:])
    }
}

public final class FakeNativeSwitchShortcuts: NativeSwitchShortcuts {
    public var shortcuts: [Int: CGEventFlags]
    public init(_ shortcuts: [Int: CGEventFlags] = [:]) { self.shortcuts = shortcuts }
    public func enabledModifiers() -> [Int: CGEventFlags] { shortcuts }
}
