import Foundation
import Testing
@testable import HyprControl

private func parse(_ s: String) -> Result<ControlCommand, ControlParseError> { ControlRequest.parse(Data(s.utf8)) }

@Test func parsesEveryCommand() {
    for c in ControlCommand.allCases {
        #expect(parse(#"{"cmd":"\#(c.rawValue)"}"#) == .success(c))
    }
    #expect(ControlCommand.togglePause.rawValue == "toggle-pause")
}

@Test func encodeRoundTrips() {
    for c in ControlCommand.allCases {
        let line = ControlRequest.encode(c)
        #expect(line.last == 0x0A)
        #expect(ControlRequest.parse(line.dropLast()) == .success(c))
    }
}

@Test func rejectsBadRequests() {
    func message(_ s: String) -> String? { if case .failure(let e) = parse(s) { return e.message }; return nil }
    #expect(message("") == "invalid JSON")
    #expect(message("not json") == "invalid JSON")
    #expect(message("[1]") == "request must be a JSON object")
    #expect(message("\"status\"") == "invalid JSON" || message("\"status\"") == "request must be a JSON object")
    #expect(message("{}") == "missing cmd")
    #expect(message(#"{"cmd":1}"#) == "cmd must be a string")
    #expect(message(#"{"cmd":null}"#) == "cmd must be a string")
    #expect(message(#"{"cmd":"explode"}"#) == "unknown command: explode")
    #expect(message(#"{"cmd":"status","x":1}"#) == "unexpected key: x")
    #expect(message(#"{"cmd":"Status"}"#) == "unknown command: Status") // case-sensitive
    #expect(message(#"{"cmd":"status "}"#) != nil)
    #expect(message(#"{"cmd":"status"} trailing"#) == "invalid JSON")
}

@Test func rejectsOversizedRequest() {
    let big = #"{"cmd":""# + String(repeating: "a", count: 2000) + #""}"#
    #expect(parse(big) == .failure(ControlParseError("request too long")))
}

@Test func echoedNamesAreSanitized() {
    guard case .failure(let e) = parse(#"{"cmd":"a\u001b[31mb\nc"# + String(repeating: "z", count: 200) + #""}"#) else {
        Issue.record("expected failure"); return
    }
    #expect(!e.message.contains("\u{1b}"))
    #expect(!e.message.contains("\n"))
    #expect(e.message.count < 80)
}

@Test func replyEncodingRoundTrips() throws {
    let ok = ControlReply.success(["paused": false, "displays": 2]).encoded()
    #expect(ok.last == 0x0A)
    let r = try #require(ControlReply.decode(ok.dropLast()))
    #expect(r.ok && r.result["displays"] as? Int == 2)
    let bad = try #require(ControlReply.decode(ControlReply.failure("nope").encoded().dropLast()))
    #expect(!bad.ok && bad.error == "nope")
    #expect(ControlReply.decode(Data("garbage".utf8)) == nil)
    #expect(ControlReply.decode(Data(#"{"result":{}}"#.utf8)) == nil)
}

@Test func defaultPathUsesTmpdir() {
    #expect(ControlSocket.defaultPath(environment: ["TMPDIR": "/var/folders/ab/cd/T/"]) == "/var/folders/ab/cd/T/dev.codesmith28.hyprmac.sock")
    #expect(ControlSocket.defaultPath(environment: ["TMPDIR": "/var/folders/ab/cd/T"]) == "/var/folders/ab/cd/T/dev.codesmith28.hyprmac.sock")
}

@Test func defaultPathFallsBackWhenTooLong() {
    let long = "/" + String(repeating: "d", count: 120)
    #expect(ControlSocket.defaultPath(environment: ["TMPDIR": long], uid: 501) == "/tmp/dev.codesmith28.hyprmac.501.sock")
}

@Test func addressRejectsBadPaths() {
    #expect(throws: ControlSocket.AddressError.pathTooLong) { try ControlSocket.address("/" + String(repeating: "a", count: 110)) }
    #expect(throws: ControlSocket.AddressError.pathHasNul) { try ControlSocket.address("/tmp/a\0b") }
    #expect((try? ControlSocket.address("/tmp/ok.sock")) != nil)
}

@Test func cliUsageErrors() {
    var out: [String] = [], err: [String] = []
    func run(_ a: [String]) -> Int32 {
        out = []; err = []
        return ControlCLI.run(arguments: ["hyprmacctl"] + a, socketPath: "/nonexistent/hm.sock", out: { out.append($0) }, err: { err.append($0) })
    }
    #expect(run([]) == 2)
    #expect(run(["a", "b"]) == 2)
    #expect(run(["explode"]) == 2)
    #expect(err.joined().contains("unknown command 'explode'"))
    #expect(run(["--help"]) == 0)
    #expect(out.joined().contains("toggle-pause"))
    #expect(run(["status"]) == 3) // nothing listening
    #expect(err.joined().contains("not running"))
}
