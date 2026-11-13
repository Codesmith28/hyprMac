import Darwin
import Foundation
import HyprControl
import HyprPlatform
import Testing
@testable import HyprKit

private final class RecordingHandler: ControlHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ControlCommand] = []
    var commands: [ControlCommand] { lock.lock(); defer { lock.unlock() }; return seen }
    func handle(_ command: ControlCommand) -> ControlReply {
        lock.lock(); seen.append(command); lock.unlock()
        return command == .status ? .success(["paused": false]) : .success()
    }
}

/// Short path: socket addresses hold ~100 bytes.
private func tempSocketPath() -> String {
    let dir = NSTemporaryDirectory() + "hm-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/c.sock"
}

private func cleanup(_ path: String) { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

/// Sends raw bytes and returns the reply line.
private func raw(_ path: String, _ bytes: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    ControlSocket.setTimeouts(fd, seconds: 3)
    #expect(try ControlSocket.connect(fd, path: path) == 0)
    #expect(ControlSocket.writeAll(fd, Data(bytes.utf8)))
    return String(decoding: ControlSocket.readLine(fd, limit: 65536).data, as: UTF8.self)
}

@Test func serverAnswersEveryCommand() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    let h = RecordingHandler()
    let server = ControlServer(path: path, handler: h)
    try server.start(); defer { server.stop() }
    for c in ControlCommand.allCases {
        let reply = try ControlClient.send(c, path: path)
        #expect(reply.ok)
    }
    #expect(h.commands == ControlCommand.allCases)
    #expect(try ControlClient.send(.status, path: path).result["paused"] as? Bool == false)
}

@Test func socketIsPrivateAndRemovedOnStop() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    let server = ControlServer(path: path, handler: RecordingHandler())
    try server.start()
    var st = stat()
    #expect(lstat(path, &st) == 0)
    #expect((st.st_mode & S_IFMT) == S_IFSOCK)
    #expect(st.st_mode & 0o777 == 0o600)
    server.stop()
    #expect(lstat(path, &st) != 0)
    #expect(throws: ControlClient.Failure.notRunning) { try ControlClient.send(.status, path: path) }
}

@Test func serverRejectsMalformedAndUnknownInput() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    let h = RecordingHandler()
    let server = ControlServer(path: path, handler: h)
    try server.start(); defer { server.stop() }
    #expect(try raw(path, "garbage\n").contains(#""ok":false"#))
    #expect(try raw(path, #"{"cmd":"explode"}"# + "\n").contains("unknown command: explode"))
    #expect(try raw(path, #"{"cmd":"status","extra":1}"# + "\n").contains("unexpected key"))
    #expect(try raw(path, "\n").contains("empty request"))
    #expect(try raw(path, String(repeating: "a", count: 5000) + "\n").contains("request too long"))
    #expect(try raw(path, String(repeating: "a", count: 5000)).contains("request too long")) // no newline at all
    #expect(h.commands.isEmpty)
}

@Test func staleSocketIsReplaced() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    // A dead socket: bound, never listening, then abandoned (like a crashed run).
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = try ControlSocket.address(path)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    close(fd)
    #expect(FileManager.default.fileExists(atPath: path))
    let server = ControlServer(path: path, handler: RecordingHandler())
    try server.start(); defer { server.stop() }
    #expect(try ControlClient.send(.status, path: path).ok)
}

@Test func liveSocketIsNeverStolen() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    let first = ControlServer(path: path, handler: RecordingHandler())
    try first.start(); defer { first.stop() }
    let second = ControlServer(path: path, handler: RecordingHandler())
    #expect(throws: ControlServer.StartError.alreadyServing) { try second.start() }
    second.stop() // must not remove the first server's socket
    #expect(try ControlClient.send(.status, path: path).ok)
}

@Test func nonSocketFileIsNeverRemoved() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    try "precious".write(toFile: path, atomically: true, encoding: .utf8)
    let server = ControlServer(path: path, handler: RecordingHandler())
    #expect(throws: ControlServer.StartError.pathOccupied) { try server.start() }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "precious")
}

@Test func serverCanRestartAfterStop() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    let server = ControlServer(path: path, handler: RecordingHandler())
    try server.start(); server.stop()
    try server.start(); defer { server.stop() }
    #expect(try ControlClient.send(.retile, path: path).ok)
}

@Test func silentClientDoesNotBlockOthers() throws {
    let path = tempSocketPath(); defer { cleanup(path) }
    let server = ControlServer(path: path, handler: RecordingHandler(), ioTimeout: 1)
    try server.start(); defer { server.stop() }
    let idle = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(idle) }
    #expect(try ControlSocket.connect(idle, path: path) == 0) // connects, sends nothing
    #expect(try ControlClient.send(.status, path: path).ok)
}

// MARK: handler

private final class FakeController: TilingController, @unchecked Sendable {
    var isPaused = false
    var osdPopup = true
    var keyBindings = KeyBindings.defaults
    weak var delegate: TilingControllerDelegate?
    var calls: [String] = []
    func start() {}
    func stop() {}
    func setPaused(_ paused: Bool, reason: String?) { calls.append("pause=\(paused)"); isPaused = paused }
    func togglePause() { setPaused(!isPaused, reason: "hotkey") }
    func retileAll() { calls.append("retile") }
    func reloadConfig() { calls.append("reload") }
}

@Test func handlerMapsCommandsToController() {
    let c = FakeController()
    let h = TilingControlHandler(controller: c, version: "9.9", configPath: "/x/init.lua", onMain: { $0() })
    #expect(h.handle(.retile).ok)
    #expect(h.handle(.reload).ok)
    #expect(h.handle(.pause).ok)
    #expect(h.handle(.resume).ok)
    #expect(h.handle(.togglePause).ok)
    #expect(h.handle(.togglePause).ok)
    #expect(c.calls == ["retile", "reload", "pause=true", "pause=false", "pause=true", "pause=false"])
}

@Test func statusReportsVersionPausedCountsAndConfig() throws {
    let c = FakeController(); c.isPaused = true
    let desk = FakeDesktop()
    _ = desk.addDisplay(1, frame: mainFrame, isMain: true, userSpaces: 3)
    _ = desk.addDisplay(2, frame: rect(1440, 0, 1920, 1080), userSpaces: 2)
    let h = TilingControlHandler(controller: c, version: "9.9", configPath: "/x/init.lua",
                                 displays: desk.displays, spaces: desk.spaces, onMain: { $0() })
    let r = h.handle(.status)
    #expect(r.ok)
    #expect(r.result["version"] as? String == "9.9")
    #expect(r.result["paused"] as? Bool == true)
    #expect(r.result["config"] as? String == "/x/init.lua")
    #expect(r.result["displays"] as? Int == 2)
    #expect(r.result["spaces"] as? Int == 5)
    #expect(c.calls.isEmpty) // status changes nothing
}
