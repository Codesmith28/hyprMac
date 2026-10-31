import CoreGraphics
import Foundation

/// A synthetic input event (top-left global points).
public enum SyntheticEvent: Equatable, Sendable {
    case mouseMove(CGPoint)
    case leftMouseDown(CGPoint)
    case leftMouseUp(CGPoint)
    case keyDown(CGKeyCode, CGEventFlags)
    case keyUp(CGKeyCode, CGEventFlags)
    /// Move the cursor without generating an event (`CGWarpMouseCursorPosition`).
    case warpCursor(CGPoint)
}

/// Posts synthetic input. The real one is `SystemEventPoster`.
public protocol EventPoster: AnyObject {
    func cursorLocation() -> CGPoint
    func post(_ event: SyntheticEvent)
}

/// Posts at `.cghidEventTap` (verified to drive the native Space switch on macOS 27.2) and
/// tags every event with `SyntheticEventMarker`.
public final class SystemEventPoster: EventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    public init() {}

    public func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public func post(_ event: SyntheticEvent) {
        let cg: CGEvent?
        switch event {
        case .mouseMove(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        case .leftMouseDown(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        case .leftMouseUp(let p):
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        case .keyDown(let k, let f), .keyUp(let k, let f):
            var down = false
            if case .keyDown = event { down = true }
            cg = CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: down)
            cg?.flags = f
        case .warpCursor(let p):
            CGWarpMouseCursorPosition(p)
            return
        }
        guard let e = cg else { return }
        e.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        e.post(tap: .cghidEventTap)
    }
}
