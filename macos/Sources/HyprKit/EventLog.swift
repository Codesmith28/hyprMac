import Foundation

/// Optional JSON-lines event log consumed by the E2E harness (`--event-log PATH`).
/// Thread-safe; a no-op when no path is configured.
public final class EventLog {
    public static let shared = EventLog()
    private let lock = NSLock()
    private var handle: FileHandle?

    public func open(path: String) {
        lock.lock(); defer { lock.unlock() }
        // Append, never truncate: the harness may pre-create the file or keep
        // one log across restarts.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    public func emit(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        var obj = fields
        obj["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

/// Command-line options understood by the app binary.
public struct AppOptions: Equatable {
    public var configPath: String?
    public var eventLogPath: String?
    /// `--check-config [path]`: validate a config, print the result and exit.
    public var checkConfig = false
    public var checkConfigPath: String?

    public init(arguments: [String]) {
        let args = Array(arguments.dropFirst())
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--config": configPath = next()
            case "--event-log": eventLogPath = next()
            case "--check-config":
                checkConfig = true
                // The path is optional: only a following non-flag argument counts.
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { checkConfigPath = next() }
            default: break // ignore -psn_* and unknown flags
            }
            i += 1
        }
    }
}
