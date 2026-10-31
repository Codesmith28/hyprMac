import Foundation

/// Read-only view of native Spaces through SkyLight.
enum Spaces {
    struct Display {
        let identifier: String
        let current: UInt64
        /// ManagedSpaceIDs of user (type 0) Spaces in Mission Control order.
        let userSpaces: [UInt64]
        let allSpaces: [(id: UInt64, type: Int)]
    }

    static var available: Bool {
        Private.mainConnection != nil && Private.copyManagedDisplaySpaces != nil && Private.getActiveSpace != nil
    }

    static func activeSpace() -> UInt64? {
        guard let conn = Private.mainConnection, let active = Private.getActiveSpace else { return nil }
        return active(conn())
    }

    static func displays() -> [Display] {
        guard let conn = Private.mainConnection, let copy = Private.copyManagedDisplaySpaces,
              let arr = copy(conn())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr.map { d in
            let ident = d["Display Identifier"] as? String ?? "?"
            let cur = (d["Current Space"] as? [String: Any]).flatMap { spaceID($0) } ?? 0
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s -> (UInt64, Int)? in
                guard let id = spaceID(s) else { return nil }
                return (id, (s["type"] as? NSNumber)?.intValue ?? -1)
            }
            return Display(identifier: ident, current: cur,
                           userSpaces: spaces.filter { $0.1 == 0 }.map { $0.0 },
                           allSpaces: spaces.map { (id: $0.0, type: $0.1) })
        }
    }

    private static func spaceID(_ d: [String: Any]) -> UInt64? {
        (d["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (d["id64"] as? NSNumber)?.uint64Value
    }

    /// The display that owns the active Space (falls back to the first one).
    static func activeDisplay() -> Display? {
        let all = displays()
        guard let active = activeSpace() else { return all.first }
        return all.first { $0.current == active || $0.allSpaces.contains { $0.id == active } } ?? all.first
    }

    static var userSpaces: [UInt64] { activeDisplay()?.userSpaces ?? [] }

    /// 1-based index of a user Space (the N of "Switch to Desktop N").
    static func index(of space: UInt64) -> Int? {
        userSpaces.firstIndex(of: space).map { $0 + 1 }
    }

    /// Poll until the active Space has not changed for `stable` seconds
    /// (a ⌥N posted during a transition animation is silently dropped).
    @discardableResult
    static func waitSettled(stable: Double = 0.5, timeout: Double = 5) -> UInt64? {
        let deadline = Date() + timeout
        var last = activeSpace()
        var since = Date()
        while Date() < deadline {
            pump(0.05)
            let now = activeSpace()
            if now != last { last = now; since = Date() }
            if Date().timeIntervalSince(since) >= stable { return last }
        }
        return last
    }

    /// Wait until `space` is active, then until the transition settled.
    static func waitActive(_ space: UInt64, timeout: Double = 5) -> Bool {
        let deadline = Date() + timeout
        while Date() < deadline {
            if activeSpace() == space {
                return waitSettled(timeout: max(1, deadline.timeIntervalSinceNow + 1)) == space
            }
            pump(0.05)
        }
        return false
    }
}

/// Sleep while letting the main run loop deliver pending work (KVO updates of
/// NSRunningApplication, etc.).
func pump(_ seconds: Double) {
    RunLoop.current.run(mode: .default, before: Date())
    if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
}
