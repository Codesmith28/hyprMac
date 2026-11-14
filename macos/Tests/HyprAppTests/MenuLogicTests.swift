import CoreGraphics
import Foundation
import Testing
import HyprKit
import HyprPlatform
@testable import HyprApp

struct MenuLogicTests {
    @Test func settingsPersistInTheStateStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hm-settings-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = AppSettings(store: AppStateStore(path: url))
        #expect(s.paused == false)
        #expect(s.osdPopupOverride == nil)
        #expect(s.osdEnabled(configDefault: false) == false)
        s.paused = true
        s.osdPopupOverride = true
        let again = AppSettings(store: AppStateStore(path: url))
        #expect(again.paused)
        #expect(again.osdPopupOverride == true)
        #expect(again.osdEnabled(configDefault: false)) // override beats the config default
        again.osdPopupOverride = nil
        #expect(AppSettings(store: AppStateStore(path: url)).osdPopupOverride == nil)
    }

    @Test func diagnosticsRows() {
        let ok = SystemSnapshot(accessibility: true, inputMonitoring: false, stageManagerOff: true, switchShortcutMatches: false)
        let rows = Diagnostics.rows(ok)
        #expect(rows.map(\.text) == ["✓ Accessibility", "✗ Input Monitoring", "✓ Stage Manager off",
                                     "✗ Desktop switch shortcut matches keys.switch"])
    }

    @Test func switchShortcutMatchUsesNativeModifiers() {
        let native = FakeNativeSwitchShortcuts([1: KeyModifiers.option.cgFlags])
        #expect(native.matches([.option]))
        #expect(!native.matches([.control]))
        #expect(!FakeNativeSwitchShortcuts().matches([.option]))
    }

    @Test func osdDisplayPicksWindowDisplayThenMouse() {
        // Primary 1000x800 at origin, a second display to its right. AppKit coordinates (bottom-left).
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let mouseOnFirst = CGPoint(x: 10, y: 10)
        // AX frame (top-left origin) on the second display.
        #expect(OSDDisplay.screenIndex(axFrame: CGRect(x: 1200, y: 100, width: 300, height: 200),
                                       screenFrames: screens, primaryHeight: 800, mouse: mouseOnFirst) == 1)
        // Centre off every display: largest overlap wins.
        #expect(OSDDisplay.screenIndex(axFrame: CGRect(x: 900, y: 100, width: 300, height: 200),
                                       screenFrames: screens, primaryHeight: 800, mouse: CGPoint(x: 1500, y: 10)) == 1)
        // No window: mouse display.
        #expect(OSDDisplay.screenIndex(axFrame: nil, screenFrames: screens, primaryHeight: 800,
                                       mouse: CGPoint(x: 1500, y: 10)) == 1)
        #expect(OSDDisplay.screenIndex(axFrame: nil, screenFrames: screens, primaryHeight: 800, mouse: mouseOnFirst) == 0)
        // Bottom-left vs top-left: a window at the AX top of the primary is on the primary.
        #expect(OSDDisplay.screenIndex(axFrame: CGRect(x: 10, y: 10, width: 100, height: 100),
                                       screenFrames: screens, primaryHeight: 800, mouse: CGPoint(x: 1500, y: 10)) == 0)
    }

    @Test func notificationActionsRoundTripAndMapToPanes() {
        for a in [NotificationAction.accessibility, .inputMonitoring, .keyboardShortcuts, .config] {
            #expect(NotificationAction(userInfo: [NotificationAction.userInfoKey: a.rawValue]) == a)
        }
        #expect(NotificationAction.accessibility.settingsURL?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        #expect(NotificationAction.inputMonitoring.settingsURL?.absoluteString.hasSuffix("Privacy_ListenEvent") == true)
        #expect(NotificationAction.config.settingsURL == nil)
        #expect(NotificationAction(userInfo: ["action": "bogus"]) == nil)
    }

    @Test func loginItemParsesAndCallsLaunchctl() throws {
        let out = "disabled services = {\n\t\"com.other\" => enabled\n\t\"dev.codesmith28.hyprmac\" => disabled\n}\n"
        #expect(LoginItem.isDisabled(printDisabledOutput: out, label: "dev.codesmith28.hyprmac"))
        #expect(!LoginItem.isDisabled(printDisabledOutput: out, label: "com.other"))
        #expect(!LoginItem.isDisabled(printDisabledOutput: "", label: "dev.codesmith28.hyprmac"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("a.plist")
        var calls: [[String]] = []
        let item = LoginItem(plist: plist, uid: 501) { args in calls.append(args); return (0, out) }
        #expect(!item.isAvailable)
        #expect(!item.setEnabled(false)) // no agent: nothing to toggle
        #expect(calls.isEmpty)
        try Data().write(to: plist)
        #expect(item.isAvailable)
        #expect(!item.isEnabled)
        #expect(item.setEnabled(true))
        #expect(calls.last == ["enable", "gui/501/dev.codesmith28.hyprmac"])
        #expect(item.setEnabled(false))
        #expect(calls.last == ["disable", "gui/501/dev.codesmith28.hyprmac"])
    }

    @Test func logCommandText() {
        #expect(AppDelegate.logCommand == "log stream --level info --predicate 'subsystem == \"dev.codesmith28.hyprmac\"'")
    }
}
