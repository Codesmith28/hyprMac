import Foundation

/// Optional JSON-lines event log consumed by the E2E harness (`--event-log PATH`).
/// Thread-safe; a no-op when no path is configured.
public final class EventLog {
    public static let shared = EventLog()
    private let lock = NSLock()
    private var handle: FileHandle?

    public func open(path: String) {
        lock.lock(); defer { lock.unlock() }
        FileManager.default.createFile(atPath: path, contents: nil)
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

    public init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--config": configPath = it.next()
            case "--event-log": eventLogPath = it.next()
            default: continue // ignore -psn_* and unknown flags
            }
        }
    }
}
