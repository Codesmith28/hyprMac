import AppKit

/// The OSD's blur view. `maskImage` is the ONLY clip of the blur; the hairline border is a stroked
/// `CAShapeLayer` that sits exactly on the mask's edge, so it can never disagree with the block's
/// corner radius. (A layer border + `cornerRadius`/`masksToBounds` on the same layer clipped the blur
/// a second time with a slightly different curve and left a visible gap.)
final class OSDEffectView: NSVisualEffectView {
    static let borderWidth: CGFloat = 0.5

    let borderLayer = CAShapeLayer()

    /// Corner radius of the mask and the border. Changing it rebuilds both.
    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            maskImage = OSDNotifier.makeCapsuleMaskImage(cornerRadius: cornerRadius)
            updateBorderPath()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        borderLayer.fillColor = nil
        borderLayer.lineWidth = Self.borderWidth
        borderLayer.zPosition = 1
        borderLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(borderLayer)
        updateBorderColor()
    }

    override func layout() {
        super.layout()
        updateBorderPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    /// The stroke is centred on its path, so the path is inset by half the line width: the stroke's
    /// outer edge then lies exactly on the view's edge, i.e. on the mask's edge.
    static func borderPath(bounds: CGRect, cornerRadius: CGFloat, lineWidth: CGFloat = borderWidth) -> CGPath {
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = max(0, min(cornerRadius - inset, min(rect.width, rect.height) / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Rebuilds the border path for the current size and radius.
    func updateBorderPath() {
        borderLayer.frame = bounds
        borderLayer.path = Self.borderPath(bounds: bounds, cornerRadius: cornerRadius)
    }

    /// Dynamic colours resolve per appearance, so resolve them here and on every appearance change.
    func updateBorderColor() {
        var color = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        }
        borderLayer.strokeColor = color
    }
}
