import Darwin
import Foundation

/// Where the control socket lives and how to address it.
public enum ControlSocket {
    public static let fileName = "dev.codesmith28.hyprmac.sock"
    /// `sun_path` holds 104 bytes on macOS, including the terminating NUL.
    static let maxPathBytes = 103

    /// `$TMPDIR/dev.codesmith28.hyprmac.sock`. `$TMPDIR` is per-user on macOS. When that path is
    /// too long for a socket address, falls back to `/tmp/dev.codesmith28.hyprmac.<uid>.sock`.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   uid: uid_t = getuid()) -> String {
        var dir = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        let path = dir + "/" + fileName
        if path.utf8.count <= maxPathBytes { return path }
        return "/tmp/dev.codesmith28.hyprmac.\(uid).sock"
    }

    public enum AddressError: Error, Equatable { case pathTooLong, pathHasNul }

    /// Fills a `sockaddr_un` for `path`.
    public static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.contains(0) else { throw AddressError.pathHasNul }
        guard bytes.count <= maxPathBytes else { throw AddressError.pathTooLong }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Connects `fd` to `path`; returns errno (0 on success).
    public static func connect(_ fd: Int32, path: String) throws -> Int32 {
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0 ? 0 : errno
    }

    public static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`; false on error or timeout.
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            while sent < data.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, data.count - sent)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Reads up to the first newline (excluded) or EOF, at most `limit` bytes.
    /// `tooLong` is set when the limit was hit before a newline.
    public static func readLine(_ fd: Int32, limit: Int) -> (data: Data, tooLong: Bool, failed: Bool) {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; return (out, false, true) }
            if n == 0 { return (out, false, false) }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return (out, out.count > limit, false)
            }
            out.append(contentsOf: buf[0..<n])
            if out.count > limit { return (out.prefix(limit), true, false) }
        }
    }
}
