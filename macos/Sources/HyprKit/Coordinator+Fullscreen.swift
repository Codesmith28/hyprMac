import Foundation
import HyprPlatform

extension Coordinator {
    /// How long a window may be missing without a Space before it counts as closed.
    static let limboGrace: TimeInterval = 2

    /// Real macOS, verified by the fullscreen-restore E2E: while a window enters fullscreen, AX stops
    /// listing it on the old Space and the window server reports it on *no* Space at all, before it
    /// ever reports `fullscreen`. Without this the engine sees a tracked window vanish, forgets its
    /// slot, and leaving fullscreen dwindle-inserts it elsewhere (swapping it with its sibling).
    ///
    /// A tracked window absent from the snapshot is handed to the engine as a ghost (`.hidden`, or
    /// `.fullscreen` once it is on a fullscreen Space of this display) when it is in that limbo: it has
    /// no Space, or only fullscreen ones. After `limboGrace` seconds with no Space it is treated as
    /// closed and forgotten (closed windows normally arrive as `destroyed` events and are purged first).
    /// A window that has a user Space, here or elsewhere (thrown away, minimized...), drops as before.
    func keepLimboGhosts(space: UInt64, display: UInt32, seen: inout Set<UInt64>,
                         entries: inout [Engine.WindowEntry]) {
        let fullscreenSpaces = Set(deps.spaces.spaces(display: display).filter { $0.kind == .fullscreen }.map(\.id))
        let now = deps.clock.now()
        for id in Array(lastStates.keys) where !seen.contains(id) && engine.space(of: id) == space {
            guard let ref = identity.ref(forEngineID: id) else { continue }
            let on = deps.spaces.spaces(of: ref.windowID)
            if !on.isEmpty, on.allSatisfy({ fullscreenSpaces.contains($0) }), !on.contains(space) {
                limboSince[id] = nil
                let old = lastStates[id]
                lastStates[id] = .fullscreen
                noteWindowStateChanged(id: id, oldState: old, newState: .fullscreen, frame: nil)
                seen.insert(id)
                entries.append(Engine.WindowEntry(id: id, state: .fullscreen))
            } else if on.isEmpty {
                let since = limboSince[id] ?? now
                limboSince[id] = since
                if now - since > Self.limboGrace {
                    forgetEngineWindow(id) // really gone
                    continue
                }
                seen.insert(id)
                entries.append(Engine.WindowEntry(id: id, state: .hidden))
                scheduleReconcile(after: 0.25) // look again soon
            } else {
                limboSince[id] = nil
            }
        }
    }
}
