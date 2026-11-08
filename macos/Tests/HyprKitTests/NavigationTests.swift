import CoreGraphics
import Foundation
import HyprPlatform
import Testing
@testable import HyprKit

@Suite struct NavigationTests {
    let original = rect(200, 200, 400, 300)
    let centred = rect(520, 312.5, 400, 300)

    private func started() -> Harness {
        let h = Harness(); h.start()
        h.c.queue.sync {}
        return h
    }

    @Test func focusDirectionSwitchesBetweenTiledWindows() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(a)
        h.settle()
        #expect((try? h.desk.ax.bool(.focused, of: a)) == true)

        h.hotkeys.pressFocus(.right)
        h.settle()
        #expect((try? h.desk.ax.bool(.focused, of: b)) == true)
        let bFrame = h.frame(b)!
        #expect(h.desk.cursorPosition == CGPoint(x: bFrame.midX, y: bFrame.midY))

        h.hotkeys.pressFocus(.left)
        h.settle()
        #expect((try? h.desk.ax.bool(.focused, of: a)) == true)
        let aFrame = h.frame(a)!
        #expect(h.desk.cursorPosition == CGPoint(x: aFrame.midX, y: aFrame.midY))
    }

    @Test func moveDirectionSwapsTiledWindowsAndKeepsFocus() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)

        h.desk.focus(a)
        h.settle()

        h.hotkeys.pressMove(.right)
        h.settle()

        #expect(h.frame(a) == rightHalf)
        #expect(h.frame(b) == leftHalf)
        #expect((try? h.desk.ax.bool(.focused, of: a)) == true)

        h.hotkeys.pressMove(.left)
        h.settle()

        #expect(h.frame(a) == leftHalf)
        #expect(h.frame(b) == rightHalf)
        #expect((try? h.desk.ax.bool(.focused, of: a)) == true)
    }

    @Test func centerWindowFloatsAndCentersTiledWindow() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(b)
        h.settle()

        h.hotkeys.pressCenterWindow()
        h.settle()

        #expect(h.c.testFloatOverride()[h.id(b)!] == true)
        #expect(h.frame(b) == centred)
        #expect(h.tiled(h.s1) == 1)
        #expect(h.frame(a) == root)
        #expect(h.recorder.notices.contains(.windowStateToggled(app: "com.example.editor", state: .floating)))
    }

    @Test func centerWindowReCentersAlreadyFloatingWindow() {
        let h = started()
        let a = h.open(1, frame: rect(100, 100, 400, 300))
        h.hotkeys.pressToggleFloat()
        h.settle()
        #expect(h.c.testFloatOverride()[h.id(a)!] == true)

        // Move it off center
        try? h.desk.ax.setPosition(CGPoint(x: 50, y: 50), of: a)
        h.settle()

        h.hotkeys.pressCenterWindow()
        h.settle()

        #expect(h.frame(a) == centred)
        let toggleNotices = h.recorder.notices.filter { if case .windowStateToggled = $0 { return true }; return false }
        #expect(toggleNotices.count == 1)
    }

    @Test func focusDirectionUsesRaiseAndSwitchesFocus() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(a)
        h.settle()
        h.desk.clearAXCalls()

        h.hotkeys.pressFocus(.right)
        h.settle()
        #expect((try? h.desk.ax.bool(.focused, of: b)) == true)
        #expect(h.desk.axCalls.contains(.raise(b)))
    }

    @Test func moveDirectionUsesRaiseToRetainFocus() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(a)
        h.settle()
        h.desk.clearAXCalls()

        h.hotkeys.pressMove(.right)
        h.settle()
        #expect(h.frame(a) == rightHalf)
        #expect(h.frame(b) == leftHalf)
        #expect(h.desk.axCalls.contains(.raise(a)))
        #expect((try? h.desk.ax.bool(.focused, of: a)) == true)
    }

    @Test func navigationAndToggleFloatWorkWithFallbackResolution() {
        let h = started()
        let a = h.open(1), b = h.open(2)
        h.desk.focus(a)
        h.settle()

        // Simulate Electron/Chromium where AX focused application returns nil
        h.desk.ax.focusedApplicationOverride = { nil }

        // Directional focus still works via resolveFocusedWindow fallback to trackedFocusedRef
        h.hotkeys.pressFocus(.right)
        h.settle()
        #expect((try? h.desk.ax.bool(.focused, of: b)) == true)

        // Center window still works via resolveFocusedWindow
        h.hotkeys.pressCenterWindow()
        h.settle()
        #expect(h.c.testFloatOverride()[h.id(b)!] == true)
        #expect(h.frame(b) == centred)

        // Toggle float still works via resolveFocusedWindow
        h.hotkeys.pressToggleFloat()
        h.settle()
        #expect(h.c.testFloatOverride()[h.id(b)!] == false)
    }
}
