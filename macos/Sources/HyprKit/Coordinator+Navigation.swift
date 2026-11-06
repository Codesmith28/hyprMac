import AppKit
import CoreGraphics
import Foundation
import HyprPlatform

/// Native window navigation and positioning:
/// - Directional focus in the BSP tree (⌥⇧H/J/K/L, ⌥⇧←/↓/↑/→)
/// - Directional window move/swap in the BSP tree (⌥⇧⌘H/J/K/L, ⌥⇧⌘←/↓/↑/→)
/// - Center window (⌥⇧C)
extension Coordinator {

    public func focus(direction: Direction) {
        queue.async { [self] in focusNow(direction: direction) }
    }

    public func move(direction: Direction) {
        queue.async { [self] in moveNow(direction: direction) }
    }

    public func centerFocusedWindow() {
        queue.async { [self] in centerFocusedWindowNow() }
    }

    // MARK: - Internal implementations on serial `queue`

    func focusNow(direction: Direction) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, !userPaused, !stageManagerPaused, !dragging, !throwInFlight else { return }
        guard let (pid, window) = resolveFocusedWindow(),
              !isIgnored(pid: pid),
              let id = idByRef[window] else { return }
        guard let currentFrame = lastTargets[id] ?? (try? deps.ax.frame(of: window)) else { return }
        let sid = engine.space(of: id)
            ?? deps.displays.display(for: currentFrame).flatMap { deps.spaces.activeSpace(display: $0.id) }
            ?? 0

        guard let targetId = findCandidate(from: id, currentFrame: currentFrame, space: sid, direction: direction),
              let targetRef = ref(for: targetId) else { return }

        _ = try? deps.ax.raise(targetRef)
        if let app = NSRunningApplication(processIdentifier: targetRef.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        if let targetFrame = lastTargets[targetId] ?? (try? deps.ax.frame(of: targetRef)) {
            let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            deps.poster.post(.warpCursor(center))
        }
        EventLog.shared.emit("focus_direction", ["window": Int(targetRef.windowID), "direction": direction.rawValue])
    }

    func moveNow(direction: Direction) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, !userPaused, !stageManagerPaused, !dragging, !throwInFlight else { return }
        guard let (pid, window) = resolveFocusedWindow(),
              !isIgnored(pid: pid),
              let id = idByRef[window],
              lastStates[id] == .tiled else { return }
        guard let currentFrame = lastTargets[id] else { return }
        let sid = engine.space(of: id)
            ?? deps.displays.display(for: currentFrame).flatMap { deps.spaces.activeSpace(display: $0.id) }
            ?? 0

        guard let targetId = findCandidate(from: id, currentFrame: currentFrame, space: sid, direction: direction) else { return }
        guard let plan = try? engine.swap(window: id, with: targetId) else { return }
        activity += 1
        apply(plan)

        // Keep focus on the moved window
        _ = try? deps.ax.raise(window)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        EventLog.shared.emit("move_direction", ["window": Int(window.windowID), "target": Int(targetId), "direction": direction.rawValue])
    }

    func centerFocusedWindowNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, !userPaused, !stageManagerPaused, !dragging, !throwInFlight else { return }
        guard let (pid, window) = resolveFocusedWindow(),
              !isIgnored(pid: pid),
              let id = idByRef[window],
              let state = lastStates[id] else { return }
        if (try? deps.ax.bool(.fullscreen, of: window)) == true || (try? deps.ax.bool(.minimized, of: window)) == true {
            return
        }
        activity += 1
        switch state {
        case .tiled:
            floatOverride[id] = true
            let frame = calculateCenteredFrame(for: window, id: id)
            reconcileNow()
            if let frame {
                firstSeenFrame[id] = frame
                executor.place(window, frame: frame)
                if let bundle = bundleID(for: window) {
                    appStateStore.save(bundleID: bundle, state: SavedAppState(state: .floating, frame: frame))
                }
            }
            EventLog.shared.emit("center_window", ["window": Int(window.windowID), "state": "floating"])
        case .floating:
            guard let frame = calculateCenteredFrame(for: window, id: id) else { return }
            firstSeenFrame[id] = frame
            executor.place(window, frame: frame)
            if let bundle = bundleID(for: window) {
                appStateStore.save(bundleID: bundle, state: SavedAppState(state: .floating, frame: frame))
            }
            EventLog.shared.emit("center_window", ["window": Int(window.windowID), "state": "floating"])
        case .minimized, .fullscreen, .hidden:
            return
        }
    }

    func calculateCenteredFrame(for window: HyprPlatform.WindowRef, id: UInt64) -> CGRect? {
        let size: CGSize
        if let original = firstSeenFrame[id]?.size, original.width > 0, original.height > 0 {
            size = original
        } else if let current = (try? deps.ax.frame(of: window))?.size, current.width > 0, current.height > 0 {
            size = current
        } else {
            size = CGSize(width: 800, height: 600)
        }
        let current = try? deps.ax.frame(of: window)
        let displays = deps.displays.displays()
        let display = current.flatMap { deps.displays.display(for: $0) }
            ?? displays.first(where: { $0.isMain }) ?? displays.first
        guard let usable = display?.visibleFrame, usable.width > 0, usable.height > 0 else { return nil }
        let w = min(size.width, usable.width), h = min(size.height, usable.height)
        let x = min(max(usable.midX - w / 2, usable.minX), usable.maxX - w)
        let y = min(max(usable.midY - h / 2, usable.minY), usable.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func ref(for id: UInt64) -> HyprPlatform.WindowRef? {
        idByRef.first(where: { $0.value == id })?.key
    }

    // MARK: - 2D Directional Candidate Matching

    func findCandidate(from sourceId: UInt64, currentFrame: CGRect, space: UInt64, direction: Direction) -> UInt64? {
        struct Candidate {
            let id: UInt64
            let frame: CGRect
            let primaryDistance: CGFloat
            let perpendicularOverlap: CGFloat
            let centerDistance: CGFloat
        }

        var candidates: [Candidate] = []

        for (otherId, targetFrame) in lastTargets where otherId != sourceId {
            guard lastStates[otherId] == .tiled else { continue }
            if space != 0, let otherSpace = engine.space(of: otherId), otherSpace != space {
                continue
            }

            let valid: Bool
            let primaryDistance: CGFloat
            let overlap: CGFloat

            switch direction {
            case .left:
                valid = targetFrame.maxX <= currentFrame.minX + 2 || targetFrame.midX < currentFrame.midX - 2
                primaryDistance = max(0, currentFrame.minX - targetFrame.maxX)
                overlap = max(0, min(currentFrame.maxY, targetFrame.maxY) - max(currentFrame.minY, targetFrame.minY))
            case .right:
                valid = targetFrame.minX >= currentFrame.maxX - 2 || targetFrame.midX > currentFrame.midX + 2
                primaryDistance = max(0, targetFrame.minX - currentFrame.maxX)
                overlap = max(0, min(currentFrame.maxY, targetFrame.maxY) - max(currentFrame.minY, targetFrame.minY))
            case .up:
                valid = targetFrame.maxY <= currentFrame.minY + 2 || targetFrame.midY < currentFrame.midY - 2
                primaryDistance = max(0, currentFrame.minY - targetFrame.maxY)
                overlap = max(0, min(currentFrame.maxX, targetFrame.maxX) - max(currentFrame.minX, targetFrame.minX))
            case .down:
                valid = targetFrame.minY >= currentFrame.maxY - 2 || targetFrame.midY > currentFrame.midY + 2
                primaryDistance = max(0, targetFrame.minY - currentFrame.maxY)
                overlap = max(0, min(currentFrame.maxX, targetFrame.maxX) - max(currentFrame.minX, targetFrame.minX))
            }

            if valid {
                let cDist = hypot(targetFrame.midX - currentFrame.midX, targetFrame.midY - currentFrame.midY)
                candidates.append(Candidate(id: otherId, frame: targetFrame, primaryDistance: primaryDistance,
                                            perpendicularOverlap: overlap, centerDistance: cDist))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Prefer overlapping candidates first; sort by smallest primary distance, then largest overlap.
        let overlapping = candidates.filter { $0.perpendicularOverlap > 0 }
        if let best = overlapping.min(by: { a, b in
            if abs(a.primaryDistance - b.primaryDistance) > 1 {
                return a.primaryDistance < b.primaryDistance
            }
            return a.perpendicularOverlap > b.perpendicularOverlap
        }) {
            return best.id
        }

        // If no overlapping candidate, pick closest by center-to-center Euclidean distance
        return candidates.min(by: { $0.centerDistance < $1.centerDistance })?.id
    }
}
