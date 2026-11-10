import Foundation
import Testing
@testable import HyprPlatform

@Suite struct SingleInstanceLockTests {
    private func tempLockPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-test-\(UUID().uuidString)")
            .appendingPathComponent("test.lock")
            .path
    }

    @Test func acquireSucceedsWhenNoOtherInstanceHoldsLock() throws {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let lock = SingleInstanceLock(lockPath: path, bundleID: "dev.codesmith28.hyprmac.test.\(UUID().uuidString)")
        #expect(lock.acquire() == .acquired)
        #expect(lock.isHeld)

        // Lockfile should contain current PID
        let content = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(content == "\(ProcessInfo.processInfo.processIdentifier)")

        lock.release()
        #expect(!lock.isHeld)
    }

    @Test func secondAcquireFailsWhenLockIsHeld() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let bundleID = "dev.codesmith28.hyprmac.test.\(UUID().uuidString)"
        let lock1 = SingleInstanceLock(lockPath: path, bundleID: bundleID)
        let lock2 = SingleInstanceLock(lockPath: path, bundleID: bundleID)

        #expect(lock1.acquire() == .acquired)
        #expect(lock2.acquire() == .lockHeldByOtherProcess)

        // After lock1 releases, lock2 can acquire
        lock1.release()
        #expect(lock2.acquire() == .acquired)
        lock2.release()
    }

    @Test func deinitReleasesFileLock() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let bundleID = "dev.codesmith28.hyprmac.test.\(UUID().uuidString)"
        do {
            let lock1 = SingleInstanceLock(lockPath: path, bundleID: bundleID)
            #expect(lock1.acquire() == .acquired)
        }

        let lock2 = SingleInstanceLock(lockPath: path, bundleID: bundleID)
        #expect(lock2.acquire() == .acquired)
        lock2.release()
    }
}
