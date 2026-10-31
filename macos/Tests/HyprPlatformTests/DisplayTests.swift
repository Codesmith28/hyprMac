import CoreGraphics
import Testing
@testable import HyprPlatform

@Suite struct DisplayTests {
    let primaryHeight: CGFloat = 900

    @Test func primaryConvertsToItself() {
        #expect(DisplayGeometry.topLeft(fromAppKit: rect(0, 0, 1440, 900), primaryHeight: primaryHeight) == rect(0, 0, 1440, 900))
        // visibleFrame with a 25 pt menu bar and a 70 pt Dock at the bottom.
        #expect(DisplayGeometry.topLeft(fromAppKit: rect(0, 70, 1440, 805), primaryHeight: primaryHeight) == rect(0, 25, 1440, 805))
    }

    @Test func displayLeftOfMain() {
        // 1920×1080 to the left, bottoms aligned.
        #expect(DisplayGeometry.topLeft(fromAppKit: rect(-1920, 0, 1920, 1080), primaryHeight: primaryHeight)
            == rect(-1920, -180, 1920, 1080))
    }

    @Test func displayAboveMain() {
        #expect(DisplayGeometry.topLeft(fromAppKit: rect(0, 900, 2560, 1440), primaryHeight: primaryHeight)
            == rect(0, -1440, 2560, 1440))
    }

    @Test func displayBelowMain() {
        #expect(DisplayGeometry.topLeft(fromAppKit: rect(200, -1080, 1920, 1080), primaryHeight: primaryHeight)
            == rect(200, 900, 1920, 1080))
    }

    let displays = [
        DisplayInfo(id: 1, frame: rect(0, 0, 1440, 900), visibleFrame: rect(0, 25, 1440, 875), isMain: true),
        DisplayInfo(id: 2, frame: rect(-1920, -180, 1920, 1080), visibleFrame: rect(-1920, -180, 1920, 1080), isMain: false),
    ]

    /// Quirk 14: negative coordinates.
    @Test func containingPointWithNegativeCoordinates() {
        #expect(DisplayGeometry.display(containing: CGPoint(x: -10, y: -100), in: displays)?.id == 2)
        #expect(DisplayGeometry.display(containing: CGPoint(x: 0, y: 0), in: displays)?.id == 1)
        #expect(DisplayGeometry.display(containing: CGPoint(x: 5000, y: 0), in: displays) == nil)
    }

    @Test func rectGoesToLargestIntersection() {
        #expect(DisplayGeometry.display(for: rect(-300, 100, 400, 300), in: displays)?.id == 2)
        #expect(DisplayGeometry.display(for: rect(-100, 100, 400, 300), in: displays)?.id == 1)
    }

    @Test func rectOffEveryDisplayGoesToNearestCentre() {
        #expect(DisplayGeometry.display(for: rect(3000, 400, 100, 100), in: displays)?.id == 1)
        #expect(DisplayGeometry.display(for: rect(-4000, 400, 100, 100), in: displays)?.id == 2)
        #expect(DisplayGeometry.display(for: rect(0, 0, 10, 10), in: []) == nil)
    }

    @Test func providerExtensionsUseFakeDesktop() {
        let desk = makeDesk()
        desk.addDisplay(2, frame: rect(-1920, -180, 1920, 1080))
        #expect(desk.displays.display(id: 2)?.frame.minX == -1920)
        #expect(desk.displays.display(containing: CGPoint(x: -1, y: 0))?.id == 2)
        #expect(desk.displays.display(for: rect(100, 100, 50, 50))?.id == 1)
    }
}
