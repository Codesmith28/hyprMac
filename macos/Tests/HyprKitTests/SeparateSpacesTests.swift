import CoreGraphics
import HyprPlatform
import Testing
@testable import HyprKit

@Test func warnsOnlyWhenOffWithSeveralDisplays() {
    #expect(SeparateSpaces.shouldWarn(displaysHaveSeparateSpaces: false, displayCount: 2))
    #expect(SeparateSpaces.shouldWarn(displaysHaveSeparateSpaces: false, displayCount: 3))
    #expect(!SeparateSpaces.shouldWarn(displaysHaveSeparateSpaces: false, displayCount: 1))
    #expect(!SeparateSpaces.shouldWarn(displaysHaveSeparateSpaces: false, displayCount: 0))
    #expect(!SeparateSpaces.shouldWarn(displaysHaveSeparateSpaces: true, displayCount: 2))
}

@Test func settingReaderTreatsAbsentAsSeparateSpacesOn() {
    struct Prefs: PreferencesReading {
        var v: Any?
        func value(key: String, domain: String) -> Any? { key == "spans-displays" && domain == "com.apple.spaces" ? v : nil }
    }
    #expect(SystemStateReader(prefs: Prefs(v: nil), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
    #expect(SystemStateReader(prefs: Prefs(v: false), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
    #expect(!SystemStateReader(prefs: Prefs(v: true), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
    #expect(!SystemStateReader(prefs: Prefs(v: 1), runningBundleIDs: { [] }).displaysHaveSeparateSpaces)
}

@Test func coordinatorWarnsOncePerRun() {
    let h = Harness()
    _ = h.desk.addDisplay(2, frame: rect(1440, 0, 1920, 1080), userSpaces: 1)
    h.system.displaysHaveSeparateSpaces = false
    h.start()
    #expect(h.recorder.count(.separateSpacesOff) == 1)
    h.send(.screenParametersChanged)
    h.send(.activeSpaceChanged)
    #expect(h.recorder.count(.separateSpacesOff) == 1)
}

@Test func coordinatorStaysQuietWithSettingOnOrOneDisplay() {
    let on = Harness()
    _ = on.desk.addDisplay(2, frame: rect(1440, 0, 1920, 1080), userSpaces: 1)
    on.start()
    #expect(on.recorder.count(.separateSpacesOff) == 0)

    let single = Harness()
    single.system.displaysHaveSeparateSpaces = false
    single.start()
    #expect(single.recorder.count(.separateSpacesOff) == 0)
}

@Test func coordinatorWarnsWhenSecondDisplayAppearsLater() {
    let h = Harness()
    h.system.displaysHaveSeparateSpaces = false
    h.start()
    #expect(h.recorder.count(.separateSpacesOff) == 0)
    _ = h.desk.addDisplay(2, frame: rect(1440, 0, 1920, 1080), userSpaces: 1)
    h.send(.screenParametersChanged)
    #expect(h.recorder.count(.separateSpacesOff) == 1)
}
