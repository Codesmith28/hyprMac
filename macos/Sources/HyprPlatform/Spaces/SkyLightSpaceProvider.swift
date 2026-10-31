import ApplicationServices
import CoreGraphics
import Foundation

/// Real `SpaceProvider` over the read-only SkyLight calls in `PrivateAPI`.
/// Falls back to `SyntheticSpaces` when symbols are missing or return nothing.
public final class SkyLightSpaceProvider: SpaceProvider, @unchecked Sendable {
    private let displayIDs: () -> [DisplayID]
    private let mainDisplay: () -> DisplayID

    /// - Parameters:
    ///   - displayIDs: the online displays (defaults to `CGGetActiveDisplayList`).
    ///   - mainDisplay: defaults to `CGMainDisplayID`.
    public init(displayIDs: @escaping () -> [DisplayID] = SkyLightSpaceProvider.activeDisplayIDs,
                mainDisplay: @escaping () -> DisplayID = { CGMainDisplayID() }) {
        self.displayIDs = displayIDs
        self.mainDisplay = mainDisplay
    }

    public var isNativeSpacesAvailable: Bool { PrivateAPI.isSpacesAvailable }

    public func activeSpace(display: DisplayID) -> SpaceID {
        if let entry = managed(display: display), let cur = entry.currentSpace { return cur }
        return SyntheticSpaces.id(for: display)
    }

    public func spaces(display: DisplayID) -> [SpaceInfo] {
        guard let entry = managed(display: display), !entry.spaces.isEmpty else {
            return SyntheticSpaces.spaces(display: display)
        }
        // With "displays have separate spaces" off, every display shares the "Main" entry.
        return entry.spaces.map { var s = $0; s.display = display; return s }
    }

    public func spaces(of window: CGWindowID) -> [SpaceID] {
        PrivateAPI.spaces(forWindow: window) ?? []
    }

    // MARK: -

    private func managed(display: DisplayID) -> ManagedDisplaySpaces? {
        guard isNativeSpacesAvailable, let raw = PrivateAPI.managedDisplaySpaces() else { return nil }
        let ids = displayIDs()
        let main = mainDisplay()
        let parsed = ManagedSpacesParser.parse(raw) { ident in
            Self.resolve(identifier: ident, displays: ids, main: main, uuid: Self.uuidString(for:))
        }
        return parsed.first { $0.display == display } ?? parsed.first { $0.identifier == "Main" }
    }

    /// Maps `"Display Identifier"` to a display: `"Main"` is the main display, otherwise the
    /// display whose UUID string matches (case-insensitive).
    public static func resolve(identifier: String, displays: [DisplayID], main: DisplayID,
                               uuid: (DisplayID) -> String?) -> DisplayID? {
        if identifier == "Main" { return main }
        return displays.first { uuid($0)?.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    /// `CGDisplayCreateUUIDFromDisplayID` as a string.
    public static func uuidString(for display: DisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static func activeDisplayIDs() -> [DisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
