import Foundation
import Testing
@testable import HyprKit

private func tempFile(_ text: String?) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let f = d.appendingPathComponent("init.lua")
    if let text { try? text.write(to: f, atomically: true, encoding: .utf8) }
    return f
}

private func run(_ args: [String]) -> (status: Int32, out: [String], err: [String]) {
    var out: [String] = [], err: [String] = []
    let s = ConfigCheck.run(options: AppOptions(arguments: ["hyprMac"] + args), out: { out.append($0) }, err: { err.append($0) })
    return (s, out, err)
}

@Test func checkConfigOptionParsing() {
    #expect(AppOptions(arguments: ["hyprMac"]).checkConfig == false)
    var o = AppOptions(arguments: ["hyprMac", "--check-config"])
    #expect(o.checkConfig && o.checkConfigPath == nil)
    o = AppOptions(arguments: ["hyprMac", "--check-config", "/tmp/a.lua"])
    #expect(o.checkConfig && o.checkConfigPath == "/tmp/a.lua")
    o = AppOptions(arguments: ["hyprMac", "--check-config", "--config", "/tmp/b.lua"])
    #expect(o.checkConfig && o.checkConfigPath == nil && o.configPath == "/tmp/b.lua")
    o = AppOptions(arguments: ["hyprMac", "--event-log", "/tmp/e", "--check-config", "x.lua"])
    #expect(o.checkConfigPath == "x.lua" && o.eventLogPath == "/tmp/e")
}

@Test func validConfigPrintsOK() {
    let f = tempFile("config = { gaps = { inner = 6, outer = 10 } }\n"); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    let r = run(["--check-config", f.path])
    #expect(r.status == 0 && r.out == ["OK"] && r.err.isEmpty)
}

@Test func syntaxErrorReportsFileAndLine() {
    let f = tempFile("config = {\n  gaps = { inner = \n}\n"); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    let r = run(["--check-config", f.path])
    #expect(r.status == 1 && r.out.isEmpty)
    let msg = r.err.joined()
    #expect(msg.hasPrefix("\(f.path):"))
    #expect(msg.range(of: #":\d+:"#, options: .regularExpression) != nil)
}

@Test func invalidValueAndUnknownKeyAreErrors() {
    let a = tempFile("config = { gaps = { inner = 9999 } }\n"); defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
    #expect(run(["--check-config", a.path]).status == 1)
    let b = tempFile("config = { gapz = {} }\n"); defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
    let r = run(["--check-config", b.path])
    #expect(r.status == 1 && r.err.joined().contains("gapz"))
}

@Test func bundledExampleValidates() throws {
    // The example shipped in the app must itself pass.
    var dir = URL(fileURLWithPath: #filePath)
    while dir.pathComponents.count > 1, !FileManager.default.fileExists(atPath: dir.appendingPathComponent("config/init.lua.example").path) {
        dir.deleteLastPathComponent()
    }
    let example = dir.appendingPathComponent("config/init.lua.example")
    try #require(FileManager.default.fileExists(atPath: example.path))
    let r = run(["--check-config", example.path])
    #expect(r.status == 0, "\(r.err)")
}

@Test func missingExplicitPathFailsButMissingDefaultDoesNot() {
    let missing = tempFile(nil); defer { try? FileManager.default.removeItem(at: missing.deletingLastPathComponent()) }
    let r = run(["--check-config", missing.path])
    #expect(r.status == 1 && r.err.joined().contains("file not found"))
    #expect(ConfigCheck.check(path: missing, required: false) == .okNoFile)
}

@Test func checkConfigFallsBackToConfigFlag() {
    let f = tempFile("config = {}\n"); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    #expect(run(["--check-config", "--config", f.path]).out == ["OK"])
}
