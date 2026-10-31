import CoreFoundation
import Foundation

/// Global macOS settings that affect tiling.
public protocol SystemStateQuery: AnyObject {
    /// Stage Manager (`com.apple.WindowManager` `GloballyEnabled`).
    var isStageManagerEnabled: Bool { get }
    /// "Displays have separate Spaces" (`com.apple.spaces` `spans-displays` is false/absent).
    var displaysHaveSeparateSpaces: Bool { get }
    /// Rectangle (`com.knollsoft.Rectangle`) is running and may fight us.
    var isRectangleRunning: Bool { get }
}

/// Reads one preference value (`CFPreferencesCopyAppValue`).
public protocol PreferencesReading {
    func value(key: String, domain: String) -> Any?
}

public struct CFPreferencesReader: PreferencesReading {
    public init() {}
    public func value(key: String, domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
}

public final class SystemStateReader: SystemStateQuery {
    public static let rectangleBundleID = "com.knollsoft.Rectangle"
    private let prefs: PreferencesReading
    private let runningBundleIDs: () -> [String]

    public init(prefs: PreferencesReading = CFPreferencesReader(),
                runningBundleIDs: @escaping () -> [String] = {
                    SystemAppProvider().runningApplications().compactMap(\.bundleID)
                }) {
        self.prefs = prefs
        self.runningBundleIDs = runningBundleIDs
    }

    public var isStageManagerEnabled: Bool {
        Self.boolValue(prefs.value(key: "GloballyEnabled", domain: "com.apple.WindowManager")) ?? false
    }

    public var displaysHaveSeparateSpaces: Bool {
        !(Self.boolValue(prefs.value(key: "spans-displays", domain: "com.apple.spaces")) ?? false)
    }

    public var isRectangleRunning: Bool { runningBundleIDs().contains(Self.rectangleBundleID) }

    /// Accepts `Bool`, numbers and "1"/"true"/"YES" strings.
    public static func boolValue(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["1", "true", "yes"].contains(s.lowercased())
        default: return nil
        }
    }
}
