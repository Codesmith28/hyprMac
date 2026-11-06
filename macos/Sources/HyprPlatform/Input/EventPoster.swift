import CoreGraphics
import Foundation

/// A synthetic input event (top-left global points).
public enum SyntheticEvent: Equatable, Sendable {
    case mouseMove(CGPoint)
    case leftMouseDown(CGPoint)
    case leftMouseDragged(CGPoint)
    case leftMouseUp(CGPoint)
    case keyDown(CGKeyCode, CGEventFlags)
    case keyUp(CGKeyCode, CGEventFlags)
    /// Move the cursor without generating an event (`CGWarpMouseCursorPosition`).
    case warpCursor(CGPoint)
}

/// Posts synthetic input. The real one is `SystemEventPoster`.
public protocol EventPoster: AnyObject {
    func cursorLocation() -> CGPoint
    /// Modifier keys physically held right now (`CGEventSource.flagsState(.hidSystemState)`).
    func physicalModifierFlags() -> CGEventFlags
    func post(_ event: SyntheticEvent)
}

/// Posts at `.cghidEventTap` (verified to drive the native Space switch on macOS 27.2) and
/// tags every event with `SyntheticEventMarker`.
///
/// Mouse events carry explicit empty flags: the throw starts while the user still holds ⌥⇧,
/// and a `.hidSystemState` source would otherwise stamp them as ⌥⇧-clicks. The source's local
/// events suppression interval is 0 so the cursor isn't "stuck" for 0.25 s after the warp.
public final class SystemEventPoster: EventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {
        source?.localEventsSuppressionInterval = 0
    }

    public func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public func physicalModifierFlags() -> CGEventFlags { CGEventSource.flagsState(.hidSystemState) }

    public func post(_ event: SyntheticEvent) {
        let cg: CGEvent?
        switch event {
        case .mouseMove(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        case .leftMouseDown(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        case .leftMouseDragged(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
        case .leftMouseUp(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
            cg?.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        case .keyDown(let k, let f), .keyUp(let k, let f):
            var down = false
            if case .keyDown = event { down = true }
            cg = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: k, keyDown: down)
            cg?.flags = f
        case .warpCursor(let p):
            CGWarpMouseCursorPosition(p)
            source?.localEventsSuppressionInterval = 0
            return
        }
        guard let e = cg else { return }
        switch event {
        case .mouseMove, .leftMouseDown, .leftMouseDragged, .leftMouseUp: e.flags = [] // never inherit held ⌥⇧
        default: break
        }
        e.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        e.post(tap: .cghidEventTap)
    }
}
