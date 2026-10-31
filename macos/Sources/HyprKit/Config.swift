import CHyprCore
import Foundation

/// Validated configuration (mirrors `hm_config`).
public struct Config: Equatable {
    public var innerGap: Double
    public var outerGap: Double
    public var splitRatio: Double

    public static var defaults: Config { var c = hm_config(); hm_config_default(&c); return Config(c) }

    init(_ c: hm_config) { innerGap = c.inner_gap; outerGap = c.outer_gap; splitRatio = c.split_ratio }
    public init(innerGap: Double, outerGap: Double, splitRatio: Double = 0.5) {
        self.innerGap = innerGap; self.outerGap = outerGap; self.splitRatio = splitRatio
    }
    var c: hm_config { hm_config(inner_gap: innerGap, outer_gap: outerGap, split_ratio: splitRatio) }
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
        if status == HM_OK {
            current = Config(c)
            return .loaded(current)
        }
        return .failedKeptPrevious(message: String(cString: err), kept: current)
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
