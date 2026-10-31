import Foundation
import Testing
@testable import HyprKit

@Test func defaultsMatchCore() {
    #expect(Config.defaults == Config(innerGap: 8, outerGap: 12, splitRatio: 0.5, floatMinWidth: 400, floatMinHeight: 300))
}

@Test func optionsParse() {
    let o = AppOptions(arguments: ["hyprMac", "-psn_0_123", "--config", "/tmp/a.lua", "--event-log", "/tmp/e.log"])
    #expect(o.configPath == "/tmp/a.lua")
    #expect(o.eventLogPath == "/tmp/e.log")
    #expect(AppOptions(arguments: ["hyprMac", "--config"]).configPath == nil)
}

@Test func missingConfigUsesDefaults() {
    let store = ConfigStore(path: URL(fileURLWithPath: "/nonexistent/hyprmac/init.lua"))
    #expect(store.load() == .missingUsedDefaults(.defaults))
}

@Test func eventLogWritesJSONLines() throws {
    let path = NSTemporaryDirectory() + "hyprmac-eventlog-\(UUID().uuidString).log"
    let log = EventLog()
    log.open(path: path)
    log.emit("started")
    log.emit("missing_space", ["n": 6, "count": 4])
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[1] == #"{"count":4,"event":"missing_space","n":6}"#)
    try? FileManager.default.removeItem(atPath: path)
}
