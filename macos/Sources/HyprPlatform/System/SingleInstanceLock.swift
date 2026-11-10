import AppKit
import Foundation

/// Ensures only a single instance of hyprMac runs per user session.
///
/// Combines LaunchServices (`NSRunningApplication`) with an atomic kernel file lock (`flock`)
/// to protect against simultaneous startup race conditions (e.g. LaunchAgent + Login Items on login).
public final class SingleInstanceLock: @unchecked Sendable {
    public enum LockResult: Equatable, Sendable {
        case acquired
        case alreadyRunning(pid: pid_t)
        case lockHeldByOtherProcess
        case cannotCreateLockDirectory(String)

        public var isAcquired: Bool { self == .acquired }
    }

    public let lockPath: String
    public let bundleID: String
    private var fileDescriptor: Int32 = -1
    private let lock = NSLock()

    public static var defaultLockPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("hyprMac/hyprMac.lock").path
    }

    public static var defaultBundleID: String {
        Bundle.main.bundleIdentifier ?? "dev.codesmith28.hyprmac"
    }

    public init(lockPath: String = defaultLockPath, bundleID: String = defaultBundleID) {
        self.lockPath = lockPath
        self.bundleID = bundleID
    }

    deinit {
        release()
    }

    /// Attempts to acquire the single-instance lock.
    ///
    /// - Returns: `.acquired` if this process is the sole active instance, or a failure case if another is running.
    @discardableResult
    public func acquire() -> LockResult {
        lock.lock()
        defer { lock.unlock() }

        let currentPID = ProcessInfo.processInfo.processIdentifier

        // 1. Check LaunchServices for an already running instance of our bundle.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        if let existing = others.first {
            return .alreadyRunning(pid: existing.processIdentifier)
        }

        // 2. Ensure lockfile directory exists.
        let dir = (lockPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .cannotCreateLockDirectory(error.localizedDescription)
        }

        // 3. Atomic kernel file lock to prevent simultaneous startup race conditions.
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // If the lockfile cannot be opened, LaunchServices check was already clean.
            return .acquired
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return .lockHeldByOtherProcess
        }

        fileDescriptor = fd

        // Record PID in lockfile for diagnostic inspection.
        ftruncate(fd, 0)
        let pidStr = "\(currentPID)\n"
        _ = pidStr.withCString { write(fd, $0, strlen($0)) }

        return .acquired
    }

    /// Releases the lock and closes the lockfile.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    /// True if this lock instance currently holds the file lock.
    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileDescriptor >= 0
    }
}
