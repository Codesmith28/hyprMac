import Carbon.HIToolbox
import Foundation
import CoreGraphics
import Testing
@testable import HyprPlatform

@Suite struct InputTests {
    @Test func digitKeycodeTable() {
        let expected: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]
        for (n, code) in expected {
            #expect(DigitKeys.keyCode(forDigit: n) == code)
            #expect(DigitKeys.digit(forKeyCode: code) == n)
        }
        #expect(DigitKeys.keyCode(forDigit: 0) == nil)
        #expect(DigitKeys.keyCode(forDigit: 10) == nil)
        #expect(DigitKeys.digit(forKeyCode: 29) == nil) // "0"
    }

    @Test func carbonKeycodeConstantsAgree() {
        #expect(CGKeyCode(kVK_ANSI_1) == 18 && CGKeyCode(kVK_ANSI_5) == 23 && CGKeyCode(kVK_ANSI_9) == 25)
    }

    @Test func hotkeyModifiersAreOptionShift() {
        #expect(HotkeyCenter.modifiers == UInt32(optionKey | shiftKey))
        #expect(HotkeyCenter.modifiers == 0x0A00)
    }

    @Test(arguments: 1...9)
    func optionDigitSwitches(_ n: Int) {
        #expect(SpaceKeyFilter.digit(keyCode: DigitKeys.keyCode(forDigit: n)!, flags: .maskAlternate) == n)
    }

    @Test(arguments: [
        CGEventFlags([.maskAlternate, .maskShift]), [.maskAlternate, .maskCommand], [.maskAlternate, .maskControl],
        [.maskAlternate, .maskSecondaryFn], [], [.maskCommand], [.maskShift],
    ])
    func otherModifierCombosIgnored(_ flags: CGEventFlags) {
        #expect(SpaceKeyFilter.digit(keyCode: 18, flags: flags) == nil)
    }

    @Test func capsLockAndDeviceBitsIgnored() {
        let flags: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskNonCoalesced, CGEventFlags(rawValue: 0x20)]
        #expect(SpaceKeyFilter.digit(keyCode: 19, flags: flags) == 2)
    }

    @Test func autorepeatSyntheticAndNonDigitsIgnored() {
        #expect(SpaceKeyFilter.digit(keyCode: 18, flags: .maskAlternate, isAutorepeat: true) == nil)
        #expect(SpaceKeyFilter.digit(keyCode: 18, flags: .maskAlternate, sourceUserData: SyntheticEventMarker.value) == nil)
        #expect(SpaceKeyFilter.digit(keyCode: 0, flags: .maskAlternate) == nil)
    }

    @Test func tapReenableTypes() {
        #expect(SpaceKeyFilter.shouldReenable(.tapDisabledByTimeout))
        #expect(SpaceKeyFilter.shouldReenable(.tapDisabledByUserInput))
        #expect(!SpaceKeyFilter.shouldReenable(.keyDown))
    }

    @Test func fakesRouteThroughFilter() {
        var got: [Int] = []
        let keys = FakeSpaceKeyObserver()
        #expect(keys.start { got.append($0) })
        keys.key(20, flags: .maskAlternate)
        keys.key(20, flags: [.maskAlternate, .maskShift])
        let hot = FakeThrowHotkeys()
        hot.failingDigits = [9]
        #expect(hot.start { got.append($0 * 10) } == [9])
        hot.press(4)
        #expect(got == [3, 40])
        keys.permitted = false
        #expect(!keys.start { _ in })
    }
}

@Suite struct SystemStateTests {
    struct Prefs: PreferencesReading {
        var values: [String: Any]
        func value(key: String, domain: String) -> Any? { values["\(domain)/\(key)"] }
    }

    @Test func stageManager() {
        #expect(SystemStateReader(prefs: Prefs(values: ["com.apple.WindowManager/GloballyEnabled": true]), runningBundleIDs: { [] }).isStageManagerEnabled)
        #expect(!SystemStateReader(prefs: Prefs(values: [:]), runningBundleIDs: { [] }).isStageManagerEnabled)
    }

    @Test func separateSpaces() {
        #expect(SystemStateReader(prefs: Prefs(values: [:]), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
        #expect(!SystemStateReader(prefs: Prefs(values: ["com.apple.spaces/spans-displays": 1]), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
        #expect(SystemStateReader(prefs: Prefs(values: ["com.apple.spaces/spans-displays": false]), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
    }

    @Test func rectangleDetection() {
        #expect(SystemStateReader(prefs: Prefs(values: [:]), runningBundleIDs: { ["com.knollsoft.Rectangle"] }).isRectangleRunning)
        #expect(!SystemStateReader(prefs: Prefs(values: [:]), runningBundleIDs: { ["com.apple.finder"] }).isRectangleRunning)
    }

    @Test func boolValueCoercion() {
        #expect(SystemStateReader.boolValue(true) == true)
        #expect(SystemStateReader.boolValue(NSNumber(value: 0)) == false)
        #expect(SystemStateReader.boolValue("YES") == true)
        #expect(SystemStateReader.boolValue(nil) == nil)
    }

    @Test func realReaderIsReadOnlyAndSafe() {
        let s = SystemStateReader()
        _ = s.isStageManagerEnabled
        _ = s.displaysHaveSeparateSpaces
        _ = s.isRectangleRunning
        let fake = FakeSystemState()
        #expect(!fake.isStageManagerEnabled && fake.displaysHaveSeparateSpaces && !fake.isRectangleRunning)
    }
}
