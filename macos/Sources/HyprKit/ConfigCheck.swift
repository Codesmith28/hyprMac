import Foundation

/// `hyprMac --check-config [path]`: validates a config with the same loader the app uses.
/// It never registers hotkeys, touches the system, or starts the app.
public enum ConfigCheck {
    public enum Outcome: Equatable {
        case ok
        /// The default location has no file: the app runs on defaults, which is fine.
        case okNoFile
        case invalid(String)
    }

    /// `required`: a missing file is an error (an explicit path was given).
    public static func check(path: URL, required: Bool) -> Outcome {
        switch ConfigStore(path: path).load() {
        case .loaded: return .ok
        case .missingUsedDefaults: return required ? .invalid("\(path.path): file not found") : .okNoFile
        case let .failedKeptPrevious(message, _): return .invalid(message)
        }
    }

    /// Path precedence: the argument of `--check-config`, then `--config`, then the default.
    public static func resolvedPath(_ options: AppOptions) -> (url: URL, explicit: Bool) {
        if let p = options.checkConfigPath ?? options.configPath {
            return (URL(fileURLWithPath: (p as NSString).expandingTildeInPath), true)
        }
        return (ConfigStore.defaultPath, false)
    }

    /// Prints `OK` (stdout) or `file:line: message` (stderr). Returns the exit status: 0 or 1.
    public static func run(options: AppOptions, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let (url, explicit) = resolvedPath(options)
        switch check(path: url, required: explicit) {
        case .ok: out("OK"); return 0
        case .okNoFile: out("OK (no config at \(url.path); defaults apply)"); return 0
        case .invalid(let message): err(message); return 1
        }
    }
}
