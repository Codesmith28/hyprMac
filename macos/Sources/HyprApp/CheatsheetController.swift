import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless panel that can take keyboard focus and closes itself on Esc.
private final class CheatsheetPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

/// Owns the shortcuts cheatsheet: opens it centered on the screen under the pointer,
/// toggles on the hotkey / menu item, closes on Esc or when it loses focus.
final class CheatsheetController: NSObject, NSWindowDelegate {
    private var panel: CheatsheetPanel?
    private let entries: () -> [CheatsheetEntry]
    private let extras: () -> [CheatsheetExtra]

    init(entries: @escaping () -> [CheatsheetEntry], extras: @escaping () -> [CheatsheetExtra]) {
        self.entries = entries
        self.extras = extras
    }

    var isShown: Bool { panel != nil }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard panel == nil else { return }
        let view = CheatsheetView(entries: entries(), extras: extras())
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let p = CheatsheetPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.onEscape = { [weak self] in self?.hide() }
        p.setFrameOrigin(Self.origin(for: size))
        p.alphaValue = 0
        panel = p

        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        p.delegate = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Centered on the screen the pointer is on, slightly above the middle.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let f = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.03)
    }
}
