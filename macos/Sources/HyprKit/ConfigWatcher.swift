import Darwin
import Dispatch
import Foundation

/// Calls `onChange` when the config file is saved with different content.
///
/// Editors save atomically (write a temp file, rename it over the target), which replaces the
/// file's inode, so watching the file itself goes blind after the first save. This watches the
/// parent directory instead, debounces bursts of events, and compares a fingerprint (mtime,
/// size, content hash) so a `touch` or a re-save of identical content does nothing. It works
/// when the file doesn't exist yet and when the directory itself appears later.
public final class ConfigWatcher {
    struct Fingerprint: Equatable {
        var mtime: timespec
        var size: Int
        var contentHash: Int?
        /// Content decides when both sides were hashed (so a `touch` or an identical re-save is
        /// not a change); mtime + size decide for files too big to hash.
        static func == (a: Fingerprint, b: Fingerprint) -> Bool {
            if let x = a.contentHash, let y = b.contentHash { return x == y }
            return a.contentHash == nil && b.contentHash == nil && a.size == b.size
                && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
        }
    }

    public let path: URL
    private let debounce: TimeInterval
    private let retryInterval: TimeInterval
    private let queue: DispatchQueue
    private let onChange: () -> Void

    // All state below is confined to `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var last: Fingerprint?
    private var running = false

    /// `onChange` runs on `queue`.
    public init(path: URL, debounce: TimeInterval = 0.3, retryInterval: TimeInterval = 2,
                queue: DispatchQueue = DispatchQueue(label: "dev.codesmith28.hyprmac.config-watcher"),
                onChange: @escaping () -> Void) {
        self.path = path; self.debounce = debounce; self.retryInterval = retryInterval
        self.queue = queue; self.onChange = onChange
    }

    deinit { stopNow() }

    /// Starts watching. The file's current state is the baseline: only later changes fire.
    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            last = fingerprint()
            attach()
        }
    }

    public func stop() { queue.sync { stopNow() } }

    private func stopNow() {
        running = false
        pending?.cancel(); pending = nil
        retry?.cancel(); retry = nil
        source?.cancel(); source = nil
    }

    // MARK: directory watching

    private func attach() {
        guard running, source == nil else { return }
        let dir = path.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { scheduleRetry(); return } // directory doesn't exist yet
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .link, .attrib], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            // The directory itself was moved or removed: drop the dead descriptor and look again.
            if !src.data.isDisjoint(with: [.rename, .delete]) {
                self.source?.cancel(); self.source = nil
                self.attach()
            }
            self.schedule()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        // The file may have been created between the baseline and the watch becoming active.
        schedule()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.retry = nil
            self.attach()
            if self.source != nil { self.schedule() }
        }
        retry = item
        queue.asyncAfter(deadline: .now() + retryInterval, execute: item)
    }

    // MARK: debounce + change detection

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func check() {
        pending = nil
        guard running else { return }
        let now = fingerprint()
        guard now != last else { return }
        last = now
        // A deleted file leaves the previous settings in place; nothing to reload.
        if now != nil { onChange() }
    }

    /// Hashing is capped; bigger files (the loader rejects them anyway) use mtime + size alone.
    private static let hashLimit = 256 * 1024

    private func fingerprint() -> Fingerprint? {
        var st = stat()
        guard stat(path.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var hash: Int?
        if st.st_size <= Self.hashLimit, let data = try? Data(contentsOf: path) {
            var h = Hasher(); h.combine(data); hash = h.finalize()
        }
        return Fingerprint(mtime: st.st_mtimespec, size: Int(st.st_size), contentHash: hash)
    }
}
