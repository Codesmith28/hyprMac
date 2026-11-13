import CHyprCore
import Foundation
import HyprPlatform

/// `config.rules`: bundle ids.
public struct AppRules: Equatable {
    /// Never managed: never tiled, never moved.
    public var ignore: [String]
    /// Always floating (⌥⇧F can still tile them); added to the built-in float list.
    public var float: [String]
    /// `rules.float_title`: windows whose first non-empty title matches float (⌥⇧F can still tile them).
    public var floatTitle: [String] { didSet { floatTitleMatcher = TitleMatcher(floatTitle) } }
    /// `rules.ignore_title`: windows whose first non-empty title matches are never managed or moved.
    public var ignoreTitle: [String]
    /// EXPERIMENTAL `rules.desktop`: bundle id → Desktop N; new windows of the app are thrown there once.
    public var desktop: [String: Int]
    public private(set) var floatTitleMatcher: TitleMatcher
    public init(ignore: [String] = [], float: [String] = [], floatTitle: [String] = [],
                ignoreTitle: [String] = [], desktop: [String: Int] = [:]) {
        self.ignore = ignore; self.float = float
        self.floatTitle = floatTitle; self.ignoreTitle = ignoreTitle; self.desktop = desktop
        self.floatTitleMatcher = TitleMatcher(floatTitle)
    }
}

/// `config.displays[<name>]`: a nil side keeps the global gap.
public struct DisplayGapOverride: Equatable {
    public var inner: Double?
    public var outer: Double?
    public init(inner: Double? = nil, outer: Double? = nil) { self.inner = inner; self.outer = outer }
}

/// Validated configuration (mirrors `hm_config`).
public struct Config: Equatable {
    public var innerGap: Double
    public var outerGap: Double
    public var splitRatio: Double
    /// Windows first seen narrower / shorter than this float (0 disables that axis).
    public var floatMinWidth: Double
    public var floatMinHeight: Double
    public var keys: KeyBindings = .defaults
    public var rules = AppRules()
    public var osdPopup: Bool = true
    /// A Space with exactly one tiled window uses zero inner and zero outer gap.
    public var smartGaps: Bool = false
    /// Hovering a window focuses it after a short debounce.
    public var focusFollowsMouse: Bool = false
    /// Per-display gap overrides keyed by `NSScreen.localizedName`.
    public var displays: [String: DisplayGapOverride] = [:]

    public static var defaults: Config { var c = hm_config(); hm_config_default(&c); return Config(c) }

    init(_ c: hm_config) {
        innerGap = c.inner_gap; outerGap = c.outer_gap; splitRatio = c.split_ratio
        floatMinWidth = c.float_min_w; floatMinHeight = c.float_min_h
    }
    public init(innerGap: Double, outerGap: Double, splitRatio: Double = 0.5,
                floatMinWidth: Double = 400, floatMinHeight: Double = 300,
                keys: KeyBindings = .defaults, rules: AppRules = AppRules(),
                osdPopup: Bool = true) {
        self.innerGap = innerGap; self.outerGap = outerGap; self.splitRatio = splitRatio
        self.floatMinWidth = floatMinWidth; self.floatMinHeight = floatMinHeight
        self.keys = keys; self.rules = rules; self.osdPopup = osdPopup
    }

    /// Parses the JSON of `hm_config_load_extras` (canonical, already validated by the core).
    public static func parseExtras(json: String) -> (keys: KeyBindings, rules: AppRules, osdPopup: Bool)? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let k = root["keys"] as? [String: String],
              let t = k["throw"], let f = k["toggle_float"], let s = k["switch"],
              var keys = KeyBindings(throw: t, toggleFloat: f, switch: s)
        else { return nil }

        // Defensive programming: prefix is hardcoded in the binary to Option + Shift for native macOS safety.
        keys.prefix = [.option, .shift]
        if let cwStr = k["center_window"], let cw = KeySpec(parsing: cwStr) {
            keys.centerWindow = cw
        }

        var customFocus: [(direction: Direction, spec: KeySpec)] = []
        if let fl = k["focus_left"].flatMap(KeySpec.init(parsing:)) { customFocus.append((.left, fl)) }
        if let fd = k["focus_down"].flatMap(KeySpec.init(parsing:)) { customFocus.append((.down, fd)) }
        if let fu = k["focus_up"].flatMap(KeySpec.init(parsing:)) { customFocus.append((.up, fu)) }
        if let fr = k["focus_right"].flatMap(KeySpec.init(parsing:)) { customFocus.append((.right, fr)) }
        if !customFocus.isEmpty {
            keys.focusKeys = customFocus
        }

        var customMove: [(direction: Direction, spec: KeySpec)] = []
        if let ml = k["move_left"].flatMap(KeySpec.init(parsing:)) { customMove.append((.left, ml)) }
        if let md = k["move_down"].flatMap(KeySpec.init(parsing:)) { customMove.append((.down, md)) }
        if let mu = k["move_up"].flatMap(KeySpec.init(parsing:)) { customMove.append((.up, mu)) }
        if let mr = k["move_right"].flatMap(KeySpec.init(parsing:)) { customMove.append((.right, mr)) }
        if !customMove.isEmpty {
            keys.moveKeys = customMove
        }

        guard let r = root["rules"] as? [String: Any],
              let ignore = r["ignore"] as? [String], let float = r["float"] as? [String]
        else { return nil }
        let osd = root["osd_popup"] as? Bool ?? true
        return (keys, AppRules(ignore: ignore, float: float), osd)
    }
    /// Reads the v0.3.0 options (title rules, `rules.desktop`, `smart_gaps`, `focus_follows_mouse`,
    /// `displays`) from the extras JSON. Absent keys keep today's behaviour; the core validated them.
    mutating func applyV3Options(json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let r = root["rules"] as? [String: Any] {
            rules.floatTitle = r["float_title"] as? [String] ?? []
            rules.ignoreTitle = r["ignore_title"] as? [String] ?? []
            var desktop: [String: Int] = [:]
            for (k, v) in r["desktop"] as? [String: Any] ?? [:] { if let n = v as? Int { desktop[k] = n } }
            rules.desktop = desktop
        }
        smartGaps = root["smart_gaps"] as? Bool ?? false
        focusFollowsMouse = root["focus_follows_mouse"] as? Bool ?? false
        var displays: [String: DisplayGapOverride] = [:]
        for (name, v) in root["displays"] as? [String: Any] ?? [:] {
            guard let d = v as? [String: Any] else { continue }
            displays[name] = DisplayGapOverride(inner: (d["inner"] as? NSNumber)?.doubleValue,
                                                outer: (d["outer"] as? NSNumber)?.doubleValue)
        }
        self.displays = displays
    }

    var c: hm_config {
        hm_config(inner_gap: innerGap, outer_gap: outerGap, split_ratio: splitRatio,
                  float_min_w: floatMinWidth, float_min_h: floatMinHeight)
    }
}

/// Loads `init.lua` through the core's sandboxed Lua loader and keeps the last valid config.
public final class ConfigStore {
    public enum LoadResult: Equatable {
        case loaded(Config)
        case missingUsedDefaults(Config)
        case failedKeptPrevious(message: String, kept: Config)
    }

    public let path: URL
    public private(set) var current: Config = .defaults

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hyprmac/init.lua")
    }

    public init(path: URL = ConfigStore.defaultPath) { self.path = path }

    @discardableResult
    public func load() -> LoadResult {
        if !FileManager.default.fileExists(atPath: path.path) {
            return .missingUsedDefaults(current)
        }
        var c = current.c
        var err = [CChar](repeating: 0, count: 1024)
        let status = hm_config_load_file(path.path, &c, &err, err.count)
        guard status == HM_OK else {
            return .failedKeptPrevious(message: String(cString: err), kept: current)
        }
        // keys and rules come through their own call (the numeric struct stays frozen).
        var json = [CChar](repeating: 0, count: 256 * 1024)
        let extrasStatus = hm_config_load_extras(path.path, &json, json.count, &err, err.count)
        guard extrasStatus == HM_OK else {
            return .failedKeptPrevious(message: String(cString: err), kept: current)
        }
        guard let extras = Config.parseExtras(json: String(cString: json)) else {
            return .failedKeptPrevious(message: "\(path.path): unreadable keys/rules", kept: current)
        }
        var loaded = Config(c)
        loaded.keys = extras.keys
        loaded.rules = extras.rules
        loaded.osdPopup = extras.osdPopup
        loaded.applyV3Options(json: String(cString: json))
        current = loaded
        return .loaded(current)
    }

    /// Creates the config file from the bundled example if it doesn't exist. Returns its URL.
    public func ensureExists(example: URL?) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) { return path }
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let example, let data = try? Data(contentsOf: example) {
            try data.write(to: path)
        } else {
            try Data("config = {\n    gaps = { inner = 8, outer = 12 },\n}\n".utf8).write(to: path)
        }
        return path
    }
}
