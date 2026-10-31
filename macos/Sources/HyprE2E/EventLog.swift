import Foundation

/// Tails hyprMac's `--event-log` file (one JSON object per line).
final class EventLog {
    struct Event {
        let seq: Int
        let at: Date          // when the harness first read the line
        let json: [String: Any]
        let raw: String
        var name: String { json["event"] as? String ?? "?" }
        func int(_ k: String) -> Int? { (json[k] as? NSNumber)?.intValue }
        func double(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        func string(_ k: String) -> String? { json[k] as? String }
    }

    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private(set) var events: [Event] = []

    init(url: URL) { self.url = url }

    /// Read whatever was appended since the last poll.
    func poll() {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            let data = try h.readToEnd() ?? Data()
            offset += UInt64(data.count)
            partial.append(data)
        } catch { return }
        while let nl = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            let raw = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                ?? ["event": "_malformed", "raw": raw]
            events.append(Event(seq: events.count, at: Date(), json: json, raw: raw))
        }
    }

    /// Position to pass to `waitFor(after:)` to only see later events.
    var cursor: Int { poll(); return events.count }

    func since(_ cursor: Int) -> ArraySlice<Event> {
        poll()
        return events[min(cursor, events.count)...]
    }

    /// Wait for the first event at or after `cursor` matching `predicate`.
    /// `abortIf` ends the wait early (e.g. the writer process died).
    func waitFor(after cursor: Int, timeout: Double, abortIf: () -> Bool = { false },
                 _ predicate: (Event) -> Bool) -> Event? {
        let deadline = Date() + timeout
        var next = cursor
        repeat {
            poll()
            while next < events.count {
                if predicate(events[next]) { return events[next] }
                next += 1
            }
            if Date() >= deadline || abortIf() { return nil }
            pump(0.02)
        } while true
    }

    func waitFor(_ name: String, after cursor: Int, timeout: Double,
                 where predicate: (Event) -> Bool = { _ in true }) -> Event? {
        waitFor(after: cursor, timeout: timeout) { $0.name == name && predicate($0) }
    }

    /// Last few raw lines, for failure messages.
    func tail(_ n: Int = 8) -> [String] {
        poll()
        return events.suffix(n).map(\.raw)
    }
}
