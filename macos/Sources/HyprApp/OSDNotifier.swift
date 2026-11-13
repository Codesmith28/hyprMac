import AppKit
import HyprKit

/// Displays a brief, non-persistent HUD / OSD overlay panel when window state changes (floated / tiled),
/// workspace switches, or windows are thrown between desktops.
public final class OSDNotifier {
    private var panel: NSPanel?
    private var visualEffectView: OSDEffectView?
    private var imageView: NSImageView?
    private var label: NSTextField?
    private var stackView: NSStackView?
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

    /// Shows the OSD notification when a window is centered on the display.
    public func showCentered(app: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showCentered(app: app)
            }
            return
        }

        let title: String
        if let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            title = "\(app): Centered"
        } else {
            title = "Centered"
        }
        let icon = Self.centeredIcon()
        display(title: title, icon: icon)
    }

    /// Shows the OSD notification when switching to Desktop N immediately and synchronously.
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
    public func showSpaceThrow(app: String?, fromSpace: Int? = nil, toSpace: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showSpaceThrow(app: app, fromSpace: fromSpace, toSpace: toSpace)
            }
            return
        }

        let title: String
        if let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            title = "\(app) ➔ Desktop \(toSpace)"
        } else {
            title = "Desktop \(toSpace)"
        }
        let icon = Self.throwIcon(fromSpace: fromSpace, toSpace: toSpace)
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
    /// Direction is based on `fromSpace` vs `toSpace`:
    /// If `toSpace < fromSpace`, left arrow ("arrow.left.to.line");
    /// otherwise right arrow ("arrow.right.to.line").
    public static func throwIcon(fromSpace: Int? = nil, toSpace: Int? = nil) -> NSImage? {
        let isLeft: Bool
        if let fromSpace, let toSpace {
            isLeft = toSpace < fromSpace
        } else {
            isLeft = false
        }
        let symbolName = isLeft ? "arrow.left.to.line" : "arrow.right.to.line"
        let fallbackName = isLeft ? "arrow.backward.square" : "arrow.forward.square"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil)
        if #available(macOS 12.0, *), let image {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            return image.withSymbolConfiguration(config)
        }
        return image
    }

    public static func throwIcon() -> NSImage? {
        throwIcon(fromSpace: nil, toSpace: nil)
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

    /// Returns the SF Symbol icon for centering a window.
    public static func centeredIcon() -> NSImage? {
        let symbolName = "viewfinder"
        let fallbackName = "scope"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "target", accessibilityDescription: nil)
        if #available(macOS 12.0, *), let image {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            return image.withSymbolConfiguration(config)
        }
        return image
    }

    /// Generates a 9-slice resizable rounded rectangle mask image matching the corner radius.
    /// Setting this on `NSVisualEffectView.maskImage` ensures WindowServer compositor clips
    /// the blur material cleanly without rectangular bleed at the rounded corners.
    public static func makeCapsuleMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2.0
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func setupPanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 44),
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

        let effect = OSDEffectView(frame: p.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 140, height: 44))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow

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
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])

        let stack = NSStackView(views: [iconView, textLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        p.contentView = effect

        self.panel = p
        self.visualEffectView = effect
        self.imageView = iconView
        self.label = textLabel
        self.stackView = stack
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
        label?.invalidateIntrinsicContentSize()
        imageView?.image = icon
        imageView?.invalidateIntrinsicContentSize()
        stackView?.layoutSubtreeIfNeeded()

        // Sizing: dynamically computed from stack fitting size plus padding (horizontal: 18pt each side, vertical: 10pt top/bottom)
        let paddingH: CGFloat = 18.0
        let paddingV: CGFloat = 10.0

        let stackFitting = stackView?.fittingSize ?? NSSize(width: 80, height: 24)
        let height = ceil(stackFitting.height + (paddingV * 2.0))
        let width = max(height, ceil(stackFitting.width + (paddingH * 2.0)))
        let cornerRadius = height / 2.0

        // Rounded corners: the 9-slice mask image is the only clip; the view strokes its own border.
        visualEffectView?.cornerRadius = cornerRadius

        panel.isOpaque = false
        panel.backgroundColor = .clear

        let panelSize = NSSize(width: width, height: height)
        let targetRect = targetFrame(for: panelSize)

        // Disable CoreAnimation actions during instantaneous frame/content updates so quick successions stay in sync
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(targetRect, display: true)
        panel.invalidateShadow()

        let isAlreadyVisible = panel.isVisible && panel.alphaValue > 0.05

        if isAlreadyVisible {
            // Already visible: instantly snap to full opacity without fade delay
            panel.alphaValue = 0.95
            CATransaction.commit()
            panel.orderFrontRegardless()
        } else {
            // First appearance: fast smooth fade-in
            panel.alphaValue = 0.0
            CATransaction.commit()
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0.95
            }
        }

        // Stays visible for ~1.2s then fades out smoothly (~0.20s) to alpha 0
        let workItem = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.20
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
