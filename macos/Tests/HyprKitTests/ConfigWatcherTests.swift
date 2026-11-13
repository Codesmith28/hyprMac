import Foundation
import Testing
@testable import HyprKit

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-watch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.02) }
    return cond()
}

/// Waits long enough for a debounce to fire (or not).
private func quiet(_ s: TimeInterval = 0.4) { Thread.sleep(forTimeInterval: s) }

private func makeWatcher(_ file: URL, _ counter: Counter, retry: TimeInterval = 0.1) -> ConfigWatcher {
    ConfigWatcher(path: file, debounce: 0.08, retryInterval: retry) { counter.bump() }
}

/// What editors do: write a temp file, rename it over the target.
private func atomicSave(_ text: String, to file: URL) throws {
    let tmp = file.deletingLastPathComponent().appendingPathComponent(".init.lua.\(UUID().uuidString.prefix(6)).tmp")
    try text.write(to: tmp, atomically: false, encoding: .utf8)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
}

@Test func watcherFiresOnInPlaceWrite() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    let n = Counter(); let w = makeWatcher(file, n); w.start(); defer { w.stop() }
    try "config = { gaps = { inner = 4 } }".write(to: file, atomically: false, encoding: .utf8)
    #expect(waitUntil { n.count == 1 })
}

@Test func watcherSurvivesRepeatedAtomicSaves() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    let n = Counter(); let w = makeWatcher(file, n); w.start(); defer { w.stop() }
    for i in 1...3 {
        try atomicSave("config = { gaps = { inner = \(i) } }", to: file)
        #expect(waitUntil { n.count == i })
        quiet(0.15)
    }
}

@Test func watcherFiresWhenFileIsCreatedLater() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    let n = Counter(); let w = makeWatcher(file, n); w.start(); defer { w.stop() }
    quiet(0.2)
    #expect(n.count == 0)
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    #expect(waitUntil { n.count == 1 })
}

@Test func watcherWorksWhenDirectoryAppearsLater() throws {
    let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("hyprmac")
    let file = dir.appendingPathComponent("init.lua")
    let n = Counter(); let w = makeWatcher(file, n); w.start(); defer { w.stop() }
    quiet(0.2)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    #expect(waitUntil { n.count == 1 })
    try atomicSave("config = { gaps = { inner = 2 } }", to: file)
    #expect(waitUntil { n.count == 2 })
}

@Test func watcherIgnoresTouchAndIdenticalResave() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    let n = Counter(); let w = makeWatcher(file, n); w.start(); defer { w.stop() }
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path) // touch
    quiet()
    try atomicSave("config = {}", to: file) // same bytes, new inode and mtime
    quiet()
    #expect(n.count == 0)
    try atomicSave("config = { gaps = { inner = 1 } }", to: file) // a real change still fires
    #expect(waitUntil { n.count == 1 })
}

@Test func watcherIgnoresUnrelatedFilesInDirectory() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    let n = Counter(); let w = makeWatcher(file, n); w.start(); defer { w.stop() }
    try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    quiet()
    #expect(n.count == 0)
}

@Test func watcherCoalescesBurstsIntoOneReload() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    let n = Counter()
    let w = ConfigWatcher(path: file, debounce: 0.3, retryInterval: 0.1) { n.bump() }
    w.start(); defer { w.stop() }
    for i in 1...5 {
        try "config = { gaps = { inner = \(i) } }".write(to: file, atomically: false, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.03)
    }
    #expect(waitUntil { n.count >= 1 })
    quiet(0.6)
    #expect(n.count == 1)
}

@Test func watcherDoesNotFireOnDeleteAndStopsAfterStop() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("init.lua")
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    let n = Counter(); let w = makeWatcher(file, n); w.start()
    try FileManager.default.removeItem(at: file)
    quiet()
    #expect(n.count == 0)
    w.stop()
    try "config = {}".write(to: file, atomically: true, encoding: .utf8)
    quiet()
    #expect(n.count == 0)
}
