import Darwin
import Dispatch
import Foundation
import HyprControl

/// Unix-domain-socket server for `hyprmacctl`: newline-delimited JSON, one request per connection.
///
/// The socket is created with mode 0600, only the owning user may talk to it, and it is
/// removed on `stop()`. A socket left behind by a crashed run is detected (nothing accepts on
/// it) and replaced; a live one is never touched.
public final class ControlServer {
    public enum StartError: Error, Equatable {
        case alreadyServing
        case pathOccupied
        case path(String)
        case system(String)
    }

    public let path: String
    private let handler: ControlHandler
    // Dedicated threads rather than GCD: the server must answer even when the dispatch pool is
    // busy (slow Accessibility calls elsewhere in the app).
    private let lock = NSLock()
    private var running = false
    private var stopRequested = false
    private var stopped: DispatchSemaphore?
    private var owned = false
    private let ioTimeout: TimeInterval

    public init(path: String = ControlSocket.defaultPath(), handler: ControlHandler, ioTimeout: TimeInterval = 2) {
        self.path = path
        self.handler = handler
        self.ioTimeout = ioTimeout
    }

    deinit { stop() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func start() throws {
        guard !isRunning else { return }
        let addr: sockaddr_un
        do { addr = try ControlSocket.address(path) } catch { throw StartError.path("\(error)") }
        try removeStaleSocket()

        // A client that hangs up before the reply must cost an EPIPE, never the process. Accepted
        // sockets inherit SO_NOSIGPIPE from the listener; setting it on a socket whose peer is
        // already gone can fail, hence also ignoring the signal (standard for socket servers).
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // No umask juggling (it is process-wide and would race with other threads creating files):
        // bind, then chmod 0600 straight away. In between, connecting needs write permission,
        // which the default umask already withholds from other users, and `serve` rejects any
        // peer whose uid isn't ours.
        var a = addr
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno
        guard rc == 0 else {
            close(fd)
            throw bindErrno == EADDRINUSE ? StartError.alreadyServing : StartError.system("bind: \(String(cString: strerror(bindErrno)))")
        }
        owned = true
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd); unlink(path); owned = false
            throw StartError.system("listen: \(msg)")
        }
        let done = DispatchSemaphore(value: 0)
        lock.lock(); running = true; stopRequested = false; stopped = done; lock.unlock()
        let thread = Thread { [weak self] in
            self?.acceptLoop(fd)
            close(fd)
            done.signal()
        }
        thread.name = "dev.codesmith28.hyprmac.control.accept"
        thread.start()
    }

    /// Stops listening and removes the socket file (only if this server created it).
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false; stopRequested = true
        let done = stopped; stopped = nil
        lock.unlock()
        _ = done?.wait(timeout: .now() + 2) // the loop polls every 100 ms
        if owned { unlink(path); owned = false }
    }

    // MARK: stale socket detection

    /// Leaves a live socket alone (`alreadyServing`), refuses to touch anything that isn't a
    /// socket of ours, and unlinks a dead one.
    private func removeStaleSocket() throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == geteuid() else { throw StartError.pathOccupied }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StartError.system("socket: \(String(cString: strerror(errno)))") }
        defer { close(probe) }
        ControlSocket.setTimeouts(probe, seconds: 1)
        let err = (try? ControlSocket.connect(probe, path: path)) ?? EINVAL
        if err == 0 { throw StartError.alreadyServing }
        if err == ECONNREFUSED || err == ENOENT { unlink(path); return }
        throw StartError.system("probe: \(String(cString: strerror(err)))")
    }

    // MARK: connections

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            lock.lock(); let quit = stopRequested; lock.unlock()
            if quit { return }
            var p = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, 100)
            if n < 0 { if errno == EINTR { continue }; return }
            if n == 0 { continue }
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            let t = Thread { [weak self] in if let self { self.serve(client) } else { close(client) } }
            t.name = "dev.codesmith28.hyprmac.control.conn"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // Blocking I/O with timeouts on the connection itself.
        ControlSocket.setTimeouts(fd, seconds: ioTimeout)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return }

        let line = ControlSocket.readLine(fd, limit: ControlRequest.maxLineBytes)
        let reply: ControlReply
        if line.failed { return }
        if line.tooLong {
            reply = .failure("request too long")
        } else if line.data.isEmpty {
            reply = .failure("empty request")
        } else {
            reply = ControlRequest.respond(to: line.data, handler: handler)
        }
        _ = ControlSocket.writeAll(fd, reply.encoded())
    }
}
