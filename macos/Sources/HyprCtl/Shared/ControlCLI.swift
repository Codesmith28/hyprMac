import Foundation

/// The `hyprmacctl` command line. Exit codes: 0 ok, 1 hyprMac refused or failed, 2 usage error,
/// 3 hyprMac isn't running.
public enum ControlCLI {
    public static let usage = """
    usage: hyprmacctl <command>

    commands:
      status        print version, paused state, display/space counts and config path as JSON
      retile        lay out every Space again
      pause         stop tiling
      resume        start tiling again
      toggle-pause  pause if running, resume if paused
      reload        re-read init.lua
    """

    public static func run(arguments: [String], socketPath: String = ControlSocket.defaultPath(),
                           out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let args = Array(arguments.dropFirst())
        if args == ["-h"] || args == ["--help"] || args == ["help"] { out(usage); return 0 }
        guard args.count == 1 else { err(usage); return 2 }
        guard let command = ControlCommand(rawValue: args[0]) else {
            err("hyprmacctl: unknown command '\(ControlRequest.sanitize(args[0]))'\n" + usage)
            return 2
        }
        do {
            let reply = try ControlClient.send(command, path: socketPath)
            guard reply.ok else { err("hyprmacctl: \(reply.error ?? "error")"); return 1 }
            if command == .status {
                let data = (try? JSONSerialization.data(withJSONObject: reply.result, options: [.sortedKeys])) ?? Data("{}".utf8)
                out(String(decoding: data, as: UTF8.self))
            } else {
                out("ok")
            }
            return 0
        } catch ControlClient.Failure.notRunning {
            err("hyprmacctl: hyprMac is not running")
            return 3
        } catch {
            err("hyprmacctl: \(error)")
            return 1
        }
    }
}
