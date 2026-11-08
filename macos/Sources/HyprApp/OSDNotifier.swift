import AppKit
import HyprKit

/// Displays a brief, non-persistent HUD / OSD overlay panel when window state changes (floated / tiled).
public final class OSDNotifier {
    private var panel: NSPanel?
    private var visualEffectView: NSVisualEffectView?
    private var imageView: NSImageView?
    private var label: NSTextField?
    private var dismissWorkItem: DispatchWorkItem?

    public init() {}

    /// Shows the OSD notification for the given application and window state.
    public func show(app: String?, state: WindowToggleState) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(app: app, state: state)
            }
            return
        }

        let title = Self.formatTitle(app: app, state: state)
        let icon = Self.icon(for: state)
        display(title: title, icon: icon)
    }

    /// Shows the OSD notification when switching to Desktop N.
    public func showSpaceSwitch(toSpace: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showSpaceSwitch(toSpace: toSpace)
            }
            return
        }

        let title = "Desktop \(toSpace)"
        let icon = Self.spaceIcon()
        display(title: title, icon: icon)
    }

    /// Shows the OSD notification when throwing a window to Desktop N.
    public func showSpaceThrow(app: String?, toSpace: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showSpaceThrow(app: app, toSpace: toSpace)
            }
            return
        }

        let title: String
        if let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            title = "\(app) ➔ Desktop \(toSpace)"
        } else {
            title = "Desktop \(toSpace)"
        }
        let icon = Self.throwIcon()
        display(title: title, icon: icon)
    }

    /// Returns the icon for switching spaces.
    public static func spaceIcon() -> NSImage? {
        let symbolName = "rectangle.stack"
        let fallbackName = "macwindow"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil)
        if #available(macOS 12.0, *), let image {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            return image.withSymbolConfiguration(config)
        }
        return image
    }

    /// Returns the icon for throwing a window to a space.
    public static func throwIcon() -> NSImage? {
        let symbolName = "arrow.right.to.line"
        let fallbackName = "arrow.forward.square"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil)
        if #available(macOS 12.0, *), let image {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            return image.withSymbolConfiguration(config)
        }
        return image
    }

    /// Formats the notification text: e.g. "Ghostty: Floated" or "Floated" / "Tiled".
    public static func formatTitle(app: String?, state: WindowToggleState) -> String {
        let stateText = state == .floating ? "Floated" : "Tiled"
        guard let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
            return stateText
        }
        return "\(app): \(stateText)"
    }

    /// Returns the SF Symbol icon for the given window state.
    public static func icon(for state: WindowToggleState) -> NSImage? {
        let symbolName = state == .floating ? "macwindow.on.rectangle" : "rectangle.split.2x1"
        let fallbackName = state == .floating ? "square.on.square" : "square.grid.2x2"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil)
        if #available(macOS 12.0, *), let image {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            return image.withSymbolConfiguration(config)
        }
        return image
    }

    private func setupPanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.alphaValue = 0.0

        let effect = NSVisualEffectView(frame: p.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 200, height: 52))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        let textLabel = NSTextField(labelWithString: "")
        textLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        textLabel.textColor = .labelColor
        textLabel.alignment = .left
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])

        let stack = NSStackView(views: [iconView, textLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        p.contentView = effect

        self.panel = p
        self.visualEffectView = effect
        self.imageView = iconView
        self.label = textLabel
        return p
    }

    private func targetFrame(for size: NSSize) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visibleRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visibleRect.midX - (size.width / 2.0)
        let preferredY = visibleRect.minY + 120.0
        let y = min(visibleRect.maxY - size.height - 20.0, max(visibleRect.minY + 60.0, preferredY))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func display(title: String, icon: NSImage?) {
        let panel = setupPanelIfNeeded()

        // Cancel pending fade-out timer
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        label?.stringValue = title
        imageView?.image = icon

        // Sizing: based on stack fitting size with pill constraints
        let stackFitting = (panel.contentView?.subviews.first as? NSStackView)?.fittingSize ?? NSSize(width: 200, height: 52)
        let width = max(180.0, min(380.0, ceil(stackFitting.width)))
        let height: CGFloat = 52.0
        let panelSize = NSSize(width: width, height: height)

        let targetRect = targetFrame(for: panelSize)
        panel.setFrame(targetRect, display: true)
        panel.invalidateShadow()

        // Fades in smoothly (~0.12s) to alpha 0.95
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0.95
        }

        // Stays visible for ~1.2s then fades out smoothly (~0.25s) to alpha 0
        let workItem = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0.0
            }, completionHandler: {
                if panel.alphaValue == 0.0 {
                    panel.orderOut(nil)
                }
            })
        }
        self.dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }
}
