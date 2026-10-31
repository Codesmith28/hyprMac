import Foundation

/// Line-delimited JSON on stdout, flushed per line. Safe from any thread.
enum Out {
    private static let lock = NSLock()

    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write("hyprmac-fixture: \(message)\n".data(using: .utf8)!)
    }
}

/// Top-left-origin rect as [x, y, w, h] (the Accessibility / CGWindowList convention).
func topLeftArray(_ r: CGRect) -> [Double] {
    let primaryHeight = NSScreenPrimaryHeight()
    return [r.origin.x, primaryHeight - (r.origin.y + r.height), r.width, r.height].map { Double($0) }
}
