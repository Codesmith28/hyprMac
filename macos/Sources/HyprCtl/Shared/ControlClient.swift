import Darwin
import Foundation

/// Sends one command to a running hyprMac and returns its reply.
public enum ControlClient {
    public enum Failure: Error, Equatable {
        case notRunning
        case io(String)
        case badReply
    }

    public static let maxReplyBytes = 64 * 1024

    public static func send(_ command: ControlCommand, path: String = ControlSocket.defaultPath(),
                            timeout: TimeInterval = 3) throws -> ControlReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        ControlSocket.setTimeouts(fd, seconds: timeout)
        let err: Int32
        do { err = try ControlSocket.connect(fd, path: path) } catch { throw Failure.io("bad socket path") }
        if err == ENOENT || err == ECONNREFUSED { throw Failure.notRunning }
        guard err == 0 else { throw Failure.io("connect: \(String(cString: strerror(err)))") }
        guard ControlSocket.writeAll(fd, ControlRequest.encode(command)) else { throw Failure.io("write failed") }
        let line = ControlSocket.readLine(fd, limit: maxReplyBytes)
        if line.failed { throw Failure.io("no reply (timed out?)") }
        guard !line.tooLong, let reply = ControlReply.decode(line.data) else { throw Failure.badReply }
        return reply
    }
}
