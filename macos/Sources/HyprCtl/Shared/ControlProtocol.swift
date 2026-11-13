import Foundation

/// A command the control socket accepts. Raw values are the names `hyprmacctl` sends.
public enum ControlCommand: String, CaseIterable, Sendable {
    case status
    case retile
    case pause
    case resume
    case togglePause = "toggle-pause"
    case reload
}

/// Reply to one request: `{"ok":true,"result":{...}}` or `{"ok":false,"error":"..."}`.
public struct ControlReply {
    public var ok: Bool
    public var result: [String: Any]
    public var error: String?

    public static func success(_ result: [String: Any] = [:]) -> ControlReply { ControlReply(ok: true, result: result, error: nil) }
    public static func failure(_ message: String) -> ControlReply { ControlReply(ok: false, result: [:], error: message) }

    /// One compact JSON line, newline included.
    public func encoded() -> Data {
        var obj: [String: Any] = ["ok": ok]
        if ok { obj["result"] = result } else { obj["error"] = error ?? "error" }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            ?? Data(#"{"error":"encoding failed","ok":false}"#.utf8)
        return data + Data("\n".utf8)
    }

    /// Parses one reply line; nil when it isn't a well-formed reply.
    public static func decode(_ line: Data) -> ControlReply? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let ok = obj["ok"] as? Bool else { return nil }
        if ok { return ControlReply(ok: true, result: obj["result"] as? [String: Any] ?? [:], error: nil) }
        return ControlReply(ok: false, result: [:], error: obj["error"] as? String ?? "error")
    }
}

/// What the app does for each command. Implementations must be thread-safe: the server calls
/// them from its connection queue.
public protocol ControlHandler: AnyObject {
    func handle(_ command: ControlCommand) -> ControlReply
}

/// Strict request parsing: newline-delimited JSON, exactly `{"cmd": "<name>"}`.
public enum ControlRequest {
    public static let maxLineBytes = 1024

    public static func parse(_ line: Data) -> Result<ControlCommand, ControlParseError> {
        guard line.count <= maxLineBytes else { return .failure(.init("request too long")) }
        guard let any = try? JSONSerialization.jsonObject(with: line) else { return .failure(.init("invalid JSON")) }
        guard let obj = any as? [String: Any] else { return .failure(.init("request must be a JSON object")) }
        if let extra = obj.keys.sorted().first(where: { $0 != "cmd" }) {
            return .failure(.init("unexpected key: \(sanitize(extra))"))
        }
        guard let cmd = obj["cmd"] else { return .failure(.init("missing cmd")) }
        guard let name = cmd as? String else { return .failure(.init("cmd must be a string")) }
        guard let command = ControlCommand(rawValue: name) else {
            return .failure(.init("unknown command: \(sanitize(name))"))
        }
        return .success(command)
    }

    /// Request line for `command` (newline included).
    public static func encode(_ command: ControlCommand) -> Data {
        Data(#"{"cmd":"\#(command.rawValue)"}"#.utf8) + Data("\n".utf8)
    }

    /// Full server-side step: request bytes in, reply out. Pure apart from the handler call.
    public static func respond(to line: Data, handler: ControlHandler) -> ControlReply {
        switch parse(line) {
        case .success(let command): return handler.handle(command)
        case .failure(let e): return .failure(e.message)
        }
    }

    /// Echoed names are clipped and stripped of control characters.
    static func sanitize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(48)))
    }
}

public struct ControlParseError: Error, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
}
