import CoreGraphics
import Foundation
import Testing
@testable import HyprPlatform

@Suite struct ManagedSpacesParsingTests {
    static func space(_ id: Int, type: Int = 0) -> [String: Any] {
        ["ManagedSpaceID": id, "id64": id, "type": type, "uuid": "U\(id)"]
    }

    let resolve: (String) -> DisplayID? = { ["Main": 1, "AAAA-1": 1, "BBBB-2": 2][$0] }

    @Test func oneDisplay() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "AAAA-1",
            "Current Space": Self.space(5),
            "Spaces": [Self.space(4), Self.space(5), Self.space(6)],
        ]]
        let out = ManagedSpacesParser.parse(raw, resolveDisplay: resolve)
        #expect(out.count == 1)
        #expect(out[0].display == 1)
        #expect(out[0].currentSpace == 5)
        #expect(out[0].spaces.map(\.id) == [4, 5, 6])
        #expect(out[0].spaces.map(\.index) == [1, 2, 3])
        #expect(out[0].spaces.allSatisfy { $0.kind == .user && $0.display == 1 })
    }

    @Test func twoDisplaysWithSeparateSpaces() {
        let raw: [[String: Any]] = [
            ["Display Identifier": "AAAA-1", "Current Space": Self.space(4), "Spaces": [Self.space(4), Self.space(5)]],
            ["Display Identifier": "BBBB-2", "Current Space": Self.space(9), "Spaces": [Self.space(7), Self.space(9)]],
        ]
        let out = ManagedSpacesParser.parse(raw, resolveDisplay: resolve)
        #expect(out.map(\.display) == [1, 2])
        #expect(out[1].currentSpace == 9)
        #expect(out[1].spaces.map(\.index) == [1, 2])
        #expect(out[1].spaces.allSatisfy { $0.display == 2 })
    }

    @Test func fullscreenSpacesMixedIn() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "Main",
            "Current Space": Self.space(12, type: 4),
            "Spaces": [Self.space(4), Self.space(12, type: 4), Self.space(5), Self.space(13, type: 4), Self.space(8)],
        ]]
        let s = ManagedSpacesParser.parse(raw, resolveDisplay: resolve)[0].spaces
        #expect(s.map(\.kind) == [.user, .fullscreen, .user, .fullscreen, .user])
        #expect(s.map(\.index) == [1, nil, 2, nil, 3])
        #expect(ManagedSpacesParser.parse(raw, resolveDisplay: resolve)[0].currentSpace == 12)
    }

    @Test func emptyInput() {
        #expect(ManagedSpacesParser.parse([], resolveDisplay: resolve).isEmpty)
        let out = ManagedSpacesParser.parse([[:]], resolveDisplay: resolve)
        #expect(out.isEmpty)
    }

    /// Verified on 27.2: user Space ids are 4, 5, 6, 8 — index ≠ id.
    @Test func nonContiguousIdsMapByPosition() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "AAAA-1", "Current Space": Self.space(4),
            "Spaces": [Self.space(4), Self.space(5), Self.space(6), Self.space(8)],
        ]]
        let s = ManagedSpacesParser.parse(raw, resolveDisplay: resolve)[0].spaces
        #expect(s.first { $0.index == 4 }?.id == 8)
    }

    @Test func prefersId64AndFallsBackToManagedSpaceID() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "AAAA-1",
            "Current Space": ["ManagedSpaceID": NSNumber(value: 3)],
            "Spaces": [["ManagedSpaceID": 1, "id64": NSNumber(value: UInt64(1) << 40), "type": 0],
                       ["ManagedSpaceID": 3, "type": NSNumber(value: 0)],
                       ["type": 0]],
        ]]
        let out = ManagedSpacesParser.parse(raw, resolveDisplay: resolve)[0]
        #expect(out.spaces.map(\.id) == [UInt64(1) << 40, 3])
        #expect(out.currentSpace == 3)
    }

    @Test func dropsUnresolvedDisplaysAndUnknownTypes() {
        let raw: [[String: Any]] = [
            ["Display Identifier": "CCCC-unknown", "Spaces": [Self.space(1)]],
            ["Display Identifier": "AAAA-1", "Spaces": [Self.space(2), Self.space(3, type: 2), Self.space(4)]],
        ]
        let out = ManagedSpacesParser.parse(raw, resolveDisplay: resolve)
        #expect(out.count == 1)
        #expect(out[0].spaces.map(\.id) == [2, 4])
        #expect(out[0].currentSpace == nil)
    }

    @Test func resolvesMainAndUUIDCaseInsensitively() {
        let uuid: (DisplayID) -> String? = { $0 == 7 ? "abcd-ef" : "1111" }
        #expect(SkyLightSpaceProvider.resolve(identifier: "Main", displays: [7, 9], main: 9, uuid: uuid) == 9)
        #expect(SkyLightSpaceProvider.resolve(identifier: "ABCD-EF", displays: [7, 9], main: 9, uuid: uuid) == 7)
        #expect(SkyLightSpaceProvider.resolve(identifier: "nope", displays: [7, 9], main: 9, uuid: uuid) == nil)
    }
}

@Suite struct SpaceProviderTests {
    @Test func syntheticIdsHaveHighBit() {
        #expect(SyntheticSpaces.id(for: 5) == (UInt64(1) << 63) | 5)
        let s = SyntheticSpaces.spaces(display: 5)
        #expect(s == [SpaceInfo(id: (UInt64(1) << 63) | 5, display: 5, kind: .user, index: 1)])
    }

    @Test func fallbackHasOneSpacePerDisplayAndNoCount() {
        let desk = makeDesk(spaces: 3)
        desk.spacesUnavailable = true
        #expect(!desk.spaces.isNativeSpacesAvailable)
        #expect(desk.spaces.spaceCount(display: 1) == nil)
        #expect(desk.spaces.userSpace(index: 1, display: 1)?.id == SyntheticSpaces.id(for: 1))
        #expect(desk.spaces.userSpace(index: 2, display: 1) == nil)
        #expect(desk.spaces.activeSpace(display: 1) == SyntheticSpaces.id(for: 1))
        #expect(desk.spaces.spaces(of: 1).isEmpty)
    }

    @Test func userSpaceIgnoresFullscreenAndCountsUsers() {
        let desk = makeDesk(spaces: 2)
        desk.addSpace(display: 1, id: 50, kind: .fullscreen)
        let third = desk.addSpace(display: 1, id: 60)
        #expect(desk.spaces.spaceCount(display: 1) == 3)
        #expect(desk.spaces.userSpace(index: 3, display: 1)?.id == third)
        #expect(desk.spaces.space(id: 50, displays: [1])?.kind == .fullscreen)
    }

    /// Read-only smoke test of the real SkyLight path. Must never crash; values depend on the host.
    @Test func skyLightProviderIsReadOnlyAndSafe() {
        let p = SkyLightSpaceProvider()
        let main = CGMainDisplayID()
        let active = p.activeSpace(display: main)
        #expect(active != 0)
        let spaces = p.spaces(display: main)
        #expect(!spaces.isEmpty)
        if !p.isNativeSpacesAvailable {
            #expect(p.spaceCount(display: main) == nil)
            #expect(spaces == SyntheticSpaces.spaces(display: main))
        } else {
            #expect(spaces.filter { $0.kind == .user }.map(\.index) == Array(1...spaces.filter { $0.kind == .user }.count).map { Optional($0) })
        }
        #expect(PrivateAPI.isSpacesAvailable == p.isNativeSpacesAvailable)
    }
}

@Suite struct TransitionGuardTests {
    @Test func blocksUntilSettled() {
        let g = SpaceTransitionGuard(settle: 0.5)
        #expect(g.canSwitch(now: 10))
        g.noteTransition(at: 10)
        #expect(!g.canSwitch(now: 10.3))
        #expect(abs(g.remaining(now: 10.3) - 0.2) < 1e-9)
        #expect(g.canSwitch(now: 10.5))
        #expect(g.remaining(now: 11) == 0)
    }

    @Test func fakeDropsSwitchDuringTransition() {
        let desk = makeDesk(spaces: 3)
        desk.poster.setCursor(CGPoint(x: 500, y: 500))
        desk.poster.post(.keyDown(19, .maskAlternate))
        desk.clock.advance(by: 0.1)
        desk.poster.post(.keyDown(20, .maskAlternate)) // dropped: transition still animating
        desk.clock.advance(by: 1)
        #expect(desk.droppedSwitches == 1)
        #expect(desk.spaces.activeSpace(display: 1) == desk.spaces.userSpace(index: 2, display: 1)?.id)
    }
}

@Suite struct WindowListParserTests {
    @Test func parsesCGWindowListDictionaries() {
        let raw: [[String: Any]] = [
            [kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 100, kCGWindowLayer as String: 0,
             kCGWindowAlpha as String: 1.0, kCGWindowIsOnscreen as String: true,
             kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200]],
            [kCGWindowNumber as String: 43, kCGWindowOwnerPID as String: 101, kCGWindowLayer as String: 25],
            [kCGWindowOwnerPID as String: 1], // no id: dropped
        ]
        let out = WindowListParser.parse(raw)
        #expect(out.count == 2)
        #expect(out[0] == OnscreenWindow(id: 42, pid: 100, layer: 0, bounds: rect(10, 20, 300, 200), alpha: 1, isOnscreen: true))
        #expect(out[1].layer == 25)
        #expect(out[1].bounds == .zero)
        #expect(!out[1].isOnscreen)
    }

    @Test func fakeWindowServerListsOnlyVisibleFrontToBack() {
        let desk = makeDesk(spaces: 2)
        let a = desk.addWindow(pid: 100, id: 1, frame: rect(0, 25, 500, 500))
        let b = desk.addWindow(pid: 100, id: 2, frame: rect(100, 25, 500, 500))
        let other = desk.addWindow(pid: 100, id: 3, frame: rect(0, 25, 500, 500), space: desk.spaces.userSpace(index: 2, display: 1)!.id)
        let ids = desk.windowServer.onscreenWindows().map(\.id)
        #expect(ids == [b.windowID, a.windowID])
        #expect(!ids.contains(other.windowID))
    }
}
