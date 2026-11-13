import AppKit
import Testing
@testable import HyprApp

/// The blur is clipped by the mask image (WindowServer), which can't be rendered offscreen, so the
/// mask image and the border layer are rendered separately into bitmaps and compared along the arc.
@MainActor
struct OSDBorderTests {
    /// Alpha plane of `draw`'s output, `scale` pixels per point, origin top-left.
    private func render(size: CGSize, scale: Int, _ draw: (CGContext) -> Void) -> (w: Int, h: Int, alpha: [Double]) {
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        gc.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw(gc.cgContext)
        gc.flushGraphics()
        NSGraphicsContext.current = saved
        var alpha = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            // bitmap rows run top-down
            alpha[y * w + x] = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        } }
        return (w, h, alpha)
    }

    /// Radius (in points, from the arc centre) where `alpha` falls through 0.5 along the ray at `angle`.
    private func edgeRadius(_ img: (w: Int, h: Int, alpha: [Double]), scale: Int, centre: CGPoint,
                            angle: Double, maxRadius: Double, from inner: Double = 0, level: Double = 0.5) -> Double? {
        var prev: (r: Double, a: Double)?
        var r = inner
        while r <= maxRadius {
            let px = Int(((centre.x + cos(angle) * r) * Double(scale)).rounded(.down)), py = Int(((centre.y + sin(angle) * r) * Double(scale)).rounded(.down))
            let a = (0..<img.w).contains(px) && (0..<img.h).contains(py) ? img.alpha[py * img.w + px] : 0
            if let p = prev, p.a >= level, a < level { return r }
            prev = (r, a)
            r += 0.05
        }
        return nil
    }

    @Test(arguments: [1, 2], [22.0, 15.0])
    func borderSitsOnTheMaskEdgeAlongTheCorner(scale: Int, radius: Double) {
        let size = CGSize(width: 200, height: radius * 2)
        let view = OSDEffectView(frame: NSRect(origin: .zero, size: size))
        view.cornerRadius = radius
        view.layoutSubtreeIfNeeded()

        let mask = render(size: size, scale: scale) { _ in
            OSDNotifier.makeCapsuleMaskImage(cornerRadius: radius)
                .draw(in: NSRect(origin: .zero, size: size))
        }
        view.borderLayer.strokeColor = NSColor.black.cgColor // visible alpha regardless of appearance
        let border = render(size: size, scale: scale) { ctx in view.borderLayer.render(in: ctx) }

        // Left-hand arc: centre (r, r), angles 90°..270° in the top-down bitmap.
        let centre = CGPoint(x: radius, y: radius)
        // Edges are located to within a pixel, and a 0.5 pt hairline covers only half a pixel at 1x.
        let tol = 1.5 / Double(scale)
        for deg in stride(from: 95.0, through: 265.0, by: 5.0) {
            let a = deg * .pi / 180
            guard let maskEdge = edgeRadius(mask, scale: scale, centre: centre, angle: a, maxRadius: radius + 2) else {
                Issue.record("no mask edge at \(deg)°"); continue
            }
            #expect(abs(maskEdge - radius) <= tol, "mask radius \(maskEdge) vs \(radius) at \(deg)°")
            // The ring's outer edge must coincide with the mask's: no gap (ring inside) or spill (outside).
            guard let ringOuter = edgeRadius(border, scale: scale, centre: centre, angle: a,
                                             maxRadius: radius + 2, from: radius - 2, level: 0.2) else {
                Issue.record("no border at \(deg)° (gap)"); continue
            }
            #expect(abs(ringOuter - maskEdge) <= tol, "border outer \(ringOuter) vs mask \(maskEdge) at \(deg)°")
        }
    }

    @Test func borderPathFollowsSizeChanges() {
        let view = OSDEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
        view.cornerRadius = 22
        view.layoutSubtreeIfNeeded()
        let before = view.borderLayer.path?.boundingBoxOfPath
        view.setFrameSize(NSSize(width: 180, height: 44))
        view.layoutSubtreeIfNeeded()
        let after = view.borderLayer.path?.boundingBoxOfPath
        #expect(before?.width != after?.width)
        #expect(after?.width == 180 - OSDEffectView.borderWidth)
        #expect(view.borderLayer.frame.size == CGSize(width: 180, height: 44))
    }

    @Test func noLayerBorderOrDuplicateClip() {
        let view = OSDEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
        view.cornerRadius = 22
        #expect(view.layer?.borderWidth == 0)
        #expect(view.layer?.cornerRadius == 0)
        #expect(view.layer?.masksToBounds == false)
        #expect(view.maskImage != nil)
    }

    @Test func borderColourTracksAppearance() {
        let view = OSDEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
        func colour(_ name: NSAppearance.Name) -> NSColor? {
            view.appearance = NSAppearance(named: name)
            view.viewDidChangeEffectiveAppearance()
            return view.borderLayer.strokeColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
        }
        let light = colour(.aqua), dark = colour(.darkAqua)
        #expect(light != nil && dark != nil)
        #expect(light != dark)
    }
}
