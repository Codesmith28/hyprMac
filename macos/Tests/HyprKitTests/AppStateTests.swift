import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

@Suite struct AppStateTests {

    private func temporaryStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-state-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func cleanUp(url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func storePersistenceRoundTrip() throws {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        let floatingFrame = rect(120, 80, 700, 500)
        store.save(bundleID: "com.example.editor", state: SavedAppState(state: .floating, frame: floatingFrame))
        store.save(bundleID: "com.example.browser", state: SavedAppState(state: .tiled))
        store.save(bundleID: "com.example.player", state: SavedAppState(state: .fullscreen))

        #expect(store.savedState(for: "com.example.editor") == SavedAppState(state: .floating, frame: floatingFrame))
        #expect(store.savedState(for: "com.example.browser") == SavedAppState(state: .tiled))
        #expect(store.savedState(for: "com.example.player") == SavedAppState(state: .fullscreen))
        #expect(store.savedState(for: "com.example.nonexistent") == nil)

        // Instantiate a second store reading from the same file on disk
        let store2 = AppStateStore(path: url)
        #expect(store2.savedState(for: "com.example.editor") == SavedAppState(state: .floating, frame: floatingFrame))
        #expect(store2.savedState(for: "com.example.browser") == SavedAppState(state: .tiled))
        #expect(store2.savedState(for: "com.example.player") == SavedAppState(state: .fullscreen))
        #expect(store2.states.count == 3)
    }

    @Test func storeRemovalAndClearing() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        store.save(bundleID: "app.a", state: SavedAppState(state: .tiled))
        store.save(bundleID: "app.b", state: SavedAppState(state: .floating))
        #expect(store.states.count == 2)

        store.remove(bundleID: "app.a")
        #expect(store.savedState(for: "app.a") == nil)
        #expect(store.savedState(for: "app.b") != nil)

        // Check re-load from disk
        let store2 = AppStateStore(path: url)
        #expect(store2.savedState(for: "app.a") == nil)
        #expect(store2.savedState(for: "app.b") != nil)

        store.clear()
        #expect(store.states.isEmpty)
        let store3 = AppStateStore(path: url)
        #expect(store3.states.isEmpty)
    }

    @Test func storeMissingAndCorruptFileHandling() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        let missingStore = AppStateStore(path: missingURL)
        #expect(missingStore.states.isEmpty)
        #expect(missingStore.savedState(for: "x") == nil)

        let corruptURL = temporaryStoreURL()
        defer { cleanUp(url: corruptURL) }
        try "not valid json {".write(to: corruptURL, atomically: true, encoding: .utf8)
        let corruptStore = AppStateStore(path: corruptURL)
        #expect(corruptStore.states.isEmpty)
    }

    @Test func coordinatorRestoresFloatingStateAndFrameOnAppOpen() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        let expectedFrame = rect(300, 200, 500, 400)
        store.save(bundleID: "com.example.editor", state: SavedAppState(state: .floating, frame: expectedFrame))

        let h = Harness(appStateStore: store)
        h.start()
        let w = h.open(1, frame: rect(100, 100, 400, 300))

        #expect(h.tiled(h.s1) == 0)
        #expect(h.c.testFloatOverride()[h.id(w)!] == true)
        #expect(h.frame(w) == expectedFrame)
    }

    @Test func coordinatorRestoresTiledStateOnAppOpen() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        store.save(bundleID: "com.example.editor", state: SavedAppState(state: .tiled))

        let h = Harness(appStateStore: store)
        h.start()
        let w = h.open(1, frame: rect(200, 200, 400, 300))

        #expect(h.tiled(h.s1) == 1)
        #expect(h.c.testFloatOverride()[h.id(w)!] == false)
        #expect(h.frame(w) == root)
    }

    @Test func coordinatorTogglingFloatUpdatesAppStateStore() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        let h = Harness(appStateStore: store)
        h.start()
        h.c.queue.sync {}

        let w = h.open(1)
        #expect(h.tiled(h.s1) == 1)

        // Toggle to floating
        h.hotkeys.pressToggleFloat()
        h.settle()

        #expect(h.tiled(h.s1) == 0)
        let savedFloating = store.savedState(for: "com.example.editor")
        #expect(savedFloating?.state == .floating)
        #expect(savedFloating?.frame != nil)
        #expect(savedFloating?.frame == h.frame(w))

        // Toggle back to tiled
        h.hotkeys.pressToggleFloat()
        h.settle()

        #expect(h.tiled(h.s1) == 1)
        let savedTiled = store.savedState(for: "com.example.editor")
        #expect(savedTiled?.state == .tiled)
    }

    @Test func appCloseAndReopenPersistsFloatingState() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        let h = Harness(appStateStore: store)
        h.start()
        h.c.queue.sync {}

        let w1 = h.open(1)
        h.hotkeys.pressToggleFloat()
        h.settle()

        let savedFrame = h.frame(w1)
        #expect(store.savedState(for: "com.example.editor")?.state == .floating)

        // Close window 1
        h.desk.closeWindow(w1)
        h.settle()
        #expect(h.c.testFloatOverride().isEmpty)

        // Reopen window 2 under the same app
        let w2 = h.open(2)
        #expect(h.tiled(h.s1) == 0)
        #expect(h.c.testFloatOverride()[h.id(w2)!] == true)
        #expect(h.frame(w2) == savedFrame)
    }

    @Test func appTerminationAndRelaunchPersistsState() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        let h = Harness(appStateStore: store)
        h.start()
        h.c.queue.sync {}

        let w1 = h.open(1, pid: 100)
        h.hotkeys.pressToggleFloat()
        h.settle()

        let savedFrame = h.frame(w1)
        #expect(store.savedState(for: "com.example.editor")?.state == .floating)

        // Terminate app pid 100
        h.desk.terminate(pid: 100)
        h.settle()
        #expect(h.c.testFloatOverride().isEmpty)

        // Relaunch app with new PID 101, same bundle ID
        h.desk.addApp(pid: 101, bundleID: "com.example.editor")
        let w2 = h.open(2, pid: 101)

        #expect(h.tiled(h.s1) == 0)
        #expect(h.c.testFloatOverride()[h.id(w2)!] == true)
        #expect(h.frame(w2) == savedFrame)
    }

    @Test func fullscreenTrackingUpdatesAppStateStore() {
        let url = temporaryStoreURL()
        defer { cleanUp(url: url) }

        let store = AppStateStore(path: url)
        let h = Harness(appStateStore: store)
        h.start()
        h.c.queue.sync {}

        let w = h.open(1)
        #expect(h.tiled(h.s1) == 1)

        // Enter fullscreen
        h.desk.setFullscreen(w, true)
        h.settle()

        #expect(store.savedState(for: "com.example.editor")?.state == .fullscreen)

        // Exit fullscreen
        h.desk.setFullscreen(w, false)
        h.settle()

        #expect(store.savedState(for: "com.example.editor")?.state == .tiled)
    }
}
