import CoreGraphics
import Foundation

/// Saved window state for an application bundle.
public struct SavedAppState: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case floating
        case tiled
        case fullscreen
    }

    public var state: State
    public var frame: CGRect?

    public init(state: State, frame: CGRect? = nil) {
        self.state = state
        self.frame = frame
    }
}

public protocol AppStateStoreProtocol: AnyObject, Sendable {
    func savedState(for bundleID: String) -> SavedAppState?
    func save(bundleID: String, state: SavedAppState)
    func remove(bundleID: String)
    var states: [String: SavedAppState] { get }
}

/// Persists application window states (floating / tiled / fullscreen, and frames) across close and reopen.
/// File storage is at `~/.config/hyprmac/state.json`. Loads on initialization, writes changes atomically.
public final class AppStateStore: AppStateStoreProtocol, @unchecked Sendable {
    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hyprmac/state.json")
    }

    public let path: URL?
    private let lock = NSLock()
    private var mapping: [String: SavedAppState] = [:]

    public init(path: URL? = AppStateStore.defaultPath) {
        self.path = path
        load()
    }

    public func savedState(for bundleID: String) -> SavedAppState? {
        lock.lock()
        defer { lock.unlock() }
        return mapping[bundleID]
    }

    public func save(bundleID: String, state: SavedAppState) {
        lock.lock()
        mapping[bundleID] = state
        let copy = mapping
        lock.unlock()
        persist(copy)
    }

    public func save(bundleID: String, state: SavedAppState.State, frame: CGRect? = nil) {
        save(bundleID: bundleID, state: SavedAppState(state: state, frame: frame))
    }

    public func setSavedState(_ state: SavedAppState, for bundleID: String) {
        save(bundleID: bundleID, state: state)
    }

    public func remove(bundleID: String) {
        lock.lock()
        mapping.removeValue(forKey: bundleID)
        let copy = mapping
        lock.unlock()
        persist(copy)
    }

    public func clear() {
        lock.lock()
        mapping.removeAll()
        let copy = mapping
        lock.unlock()
        persist(copy)
    }

    public var states: [String: SavedAppState] {
        lock.lock()
        defer { lock.unlock() }
        return mapping
    }

    public subscript(bundleID: String) -> SavedAppState? {
        get { savedState(for: bundleID) }
        set {
            if let newValue {
                save(bundleID: bundleID, state: newValue)
            } else {
                remove(bundleID: bundleID)
            }
        }
    }

    private func load() {
        guard let path else { return }
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let data = try Data(contentsOf: path)
            let decoded = try JSONDecoder().decode([String: SavedAppState].self, from: data)
            lock.lock()
            mapping = decoded
            lock.unlock()
        } catch {
            // Corrupt or invalid JSON; start empty
        }
    }

    private func persist(_ snapshot: [String: SavedAppState]) {
        guard let path else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
        } catch {
            // Write failed (e.g. read-only filesystem)
        }
    }
}
