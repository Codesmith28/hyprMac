import Foundation

/// "Launch at login" for the LaunchAgent that `make install` created. Deliberately NOT SMAppService:
/// that would register a second login item and bring back the duplicate-instance bug fixed in 0.2.2.
/// Toggling uses `launchctl enable|disable`; the override lives in launchd's database, which is why
/// `scripts/uninstall.sh` enables the label again before removing the agent.
struct LoginItem {
    static let label = "dev.codesmith28.hyprmac"

    /// Runs launchctl with `args`; returns the exit status and stdout.
    typealias Runner = ([String]) -> (status: Int32, output: String)

    let plist: URL
    let uid: uid_t
    let run: Runner

    init(plist: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(LoginItem.label).plist"),
         uid: uid_t = getuid(), run: @escaping Runner = LoginItem.launchctl) {
        self.plist = plist; self.uid = uid; self.run = run
    }

    /// Only an install-managed agent can be toggled.
    var isAvailable: Bool { FileManager.default.fileExists(atPath: plist.path) }

    /// Enabled unless launchd's override database says `disabled`.
    var isEnabled: Bool {
        let r = run(["print-disabled", "gui/\(uid)"])
        guard r.status == 0 else { return true }
        return !Self.isDisabled(printDisabledOutput: r.output, label: Self.label)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        return run([enabled ? "enable" : "disable", "gui/\(uid)/\(Self.label)"]).status == 0
    }

    /// `"label" => disabled` (older macOS: `=> true`).
    static func isDisabled(printDisabledOutput: String, label: String) -> Bool {
        for line in printDisabledOutput.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3, parts[0] == "\"\(label)\"", parts[1] == "=>" else { continue }
            return parts[2] == "disabled" || parts[2] == "true"
        }
        return false
    }

    static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
