import CoreGraphics
import Testing
@testable import HyprPlatform

@Suite struct EligibilityTests {
    let app = AppInfo(pid: 1, bundleID: "com.example.app")
    let frame = rect(0, 25, 800, 600)
    var on: OnscreenWindow { OnscreenWindow(id: 1, pid: 1, bounds: frame) }

    func eval(_ f: WindowFacts, onscreen: OnscreenWindow?? = nil, app: AppInfo? = nil) -> Eligibility {
        let o: OnscreenWindow?
        switch onscreen {
        case .none: o = on
        case .some(let x): o = x
        }
        return WindowEligibility.evaluate(f, onscreen: o, app: app ?? self.app)
    }

    @Test func standardWindowIsTiled() { #expect(eval(WindowFacts(frame: frame)) == .managed(.tiled)) }

    @Test(arguments: ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXUnknown"])
    func nonStandardSubrolesExcluded(_ subrole: String) {
        #expect(eval(WindowFacts(subrole: subrole, frame: frame)) == .excluded(.subrole(subrole)))
    }

    @Test func dialogExcluded() { #expect(eval(WindowFacts(subrole: "AXDialog", frame: frame)) == .excluded(.subrole("AXDialog"))) }

    @Test func systemDialogExcluded() {
        #expect(eval(WindowFacts(subrole: "AXSystemDialog", frame: frame)).state == nil)
    }

    @Test func floatingPanelExcluded() {
        #expect(eval(WindowFacts(subrole: "AXFloatingWindow", frame: frame)).state == nil)
    }

    @Test(arguments: ["AXSheet", "AXPopover", "AXDrawer"])
    func nonWindowRolesExcluded(_ role: String) {
        #expect(eval(WindowFacts(role: role, subrole: nil, frame: frame)) == .excluded(.role(role)))
    }

    /// Spike S12: Finder's desktop window has no subrole and a full-screen frame.
    @Test func finderDesktopWithoutSubroleExcluded() {
        let finder = AppInfo(pid: 2, bundleID: "com.apple.finder")
        let f = WindowFacts(subrole: nil, frame: rect(0, 0, 1440, 900), isResizable: false, bundleID: "com.apple.finder")
        #expect(eval(f, app: finder) == .excluded(.subrole(nil)))
    }

    @Test func accessoryAndProhibitedAppsExcluded() {
        for policy in [ActivationPolicy.accessory, .prohibited] {
            let a = AppInfo(pid: 1, bundleID: "x", activationPolicy: policy)
            #expect(eval(WindowFacts(frame: frame), app: a) == .excluded(.notRegularApp))
        }
    }

    @Test func ownBundleExcluded() {
        let me = AppInfo(pid: 1, bundleID: WindowEligibility.ownBundleID)
        #expect(eval(WindowFacts(frame: frame), app: me) == .excluded(.ownApp))
    }

    @Test(arguments: [-1, 3, 8, 25, 1000])
    func nonZeroLayerExcluded(_ layer: Int) {
        let o = OnscreenWindow(id: 1, pid: 1, layer: layer, bounds: frame)
        #expect(eval(WindowFacts(frame: frame), onscreen: o) == .excluded(.layer(layer)))
    }

    @Test func fullyTransparentExcluded() {
        let o = OnscreenWindow(id: 1, pid: 1, bounds: frame, alpha: 0)
        #expect(eval(WindowFacts(frame: frame), onscreen: o) == .excluded(.transparent))
    }

    @Test func zeroSizeExcluded() {
        #expect(eval(WindowFacts(frame: rect(0, 0, 0, 600))) == .excluded(.zeroSize))
        let o = OnscreenWindow(id: 1, pid: 1, bounds: rect(0, 0, 800, 0))
        #expect(eval(WindowFacts(frame: frame), onscreen: o) == .excluded(.zeroSize))
    }

    @Test func nonResizableFloats() {
        #expect(eval(WindowFacts(frame: frame, isResizable: false)) == .managed(.floating))
    }

    @Test func noCloseButtonFloats() {
        #expect(eval(WindowFacts(frame: frame, hasCloseButton: false)) == .managed(.floating))
    }

    @Test func floatListFloatsButSystemSettingsTiles() {
        let calc = AppInfo(pid: 1, bundleID: "com.apple.calculator")
        #expect(eval(WindowFacts(frame: frame), app: calc) == .managed(.floating))
        let settings = AppInfo(pid: 1, bundleID: "com.apple.systempreferences")
        #expect(eval(WindowFacts(frame: frame), app: settings) == .managed(.tiled))
        #expect(WindowEligibility.defaultFloatBundleIDs.count <= 3)
    }

    @Test func minimizedWithoutOnscreenEntry() {
        #expect(eval(WindowFacts(frame: frame, isMinimized: true), onscreen: .some(nil)) == .managed(.minimized))
    }

    /// Quirk 11: fullscreen keeps subrole AXStandardWindow; AXFullScreen decides.
    @Test func fullscreenState() {
        #expect(eval(WindowFacts(frame: frame, isFullscreen: true)) == .managed(.fullscreen))
    }

    @Test func hiddenAppState() {
        let hidden = AppInfo(pid: 1, bundleID: "x", isHidden: true)
        #expect(eval(WindowFacts(frame: frame), onscreen: .some(nil), app: hidden) == .managed(.hidden))
    }

    @Test func minimizedBeatsHiddenAndFloatingRules() {
        let hidden = AppInfo(pid: 1, bundleID: "x", isHidden: true)
        #expect(eval(WindowFacts(frame: frame, isMinimized: true, isResizable: false), onscreen: .some(nil), app: hidden)
            == .managed(.minimized))
    }

    @Test func offscreenStandardWindowStillEvaluates() {
        #expect(eval(WindowFacts(frame: frame), onscreen: .some(nil)) == .managed(.tiled))
    }
}
