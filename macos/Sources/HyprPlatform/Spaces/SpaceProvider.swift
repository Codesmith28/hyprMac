import CoreGraphics
import Foundation

/// Read-only view of native Spaces.
public protocol SpaceProvider: AnyObject {
    /// `false` when SkyLight symbols are missing; the provider then reports one synthetic
    /// user Space per display and `spaceCount` returns nil.
    var isNativeSpacesAvailable: Bool { get }
    /// The Space currently shown on `display`.
    func activeSpace(display: DisplayID) -> SpaceID
    /// All Spaces of `display` in Mission Control order (user and fullscreen).
    func spaces(display: DisplayID) -> [SpaceInfo]
    /// The Spaces a window is on; empty when unknown (e.g. minimized, or no SkyLight).
    func spaces(of window: CGWindowID) -> [SpaceID]
}

extension SpaceProvider {
    /// Number of user Spaces on `display`, or nil when native Spaces are unavailable.
    public func spaceCount(display: DisplayID) -> Int? {
        guard isNativeSpacesAvailable else { return nil }
        return spaces(display: display).filter { $0.kind == .user }.count
    }

    /// The N-th (1-based) user Space of `display`. Never maps N to a raw id.
    public func userSpace(index: Int, display: DisplayID) -> SpaceInfo? {
        spaces(display: display).first { $0.kind == .user && $0.index == index }
    }

    /// Looks up a Space by id across `displays`.
    public func space(id: SpaceID, displays: [DisplayID]) -> SpaceInfo? {
        for d in displays { if let s = spaces(display: d).first(where: { $0.id == id }) { return s } }
        return nil
    }
}

/// Synthetic Spaces used when SkyLight is unavailable: one user Space per display.
public enum SyntheticSpaces {
    /// High bit set so synthetic ids never collide with native ones.
    public static func id(for display: DisplayID) -> SpaceID { (1 << 63) | SpaceID(display) }
    public static func spaces(display: DisplayID) -> [SpaceInfo] {
        [SpaceInfo(id: id(for: display), display: display, kind: .user, index: 1)]
    }
}

/// One entry of `CGSCopyManagedDisplaySpaces`, parsed.
public struct ManagedDisplaySpaces: Equatable, Sendable {
    /// `"Display Identifier"`: a display UUID string, or `"Main"`.
    public var identifier: String
    public var display: DisplayID
    public var currentSpace: SpaceID?
    public var spaces: [SpaceInfo]
}

/// Pure parser for `CGSCopyManagedDisplaySpaces` output.
public enum ManagedSpacesParser {
    public static let userType = 0
    public static let fullscreenType = 4

    /// - Parameters:
    ///   - raw: the bridged array of dictionaries.
    ///   - resolveDisplay: maps `"Display Identifier"` (UUID or `"Main"`) to a display id.
    /// Entries whose display can't be resolved are dropped. Space types other than
    /// user (0) and fullscreen (4) are ignored. User indices are 1-based in array order.
    public static func parse(_ raw: [[String: Any]], resolveDisplay: (String) -> DisplayID?) -> [ManagedDisplaySpaces] {
        raw.compactMap { entry in
            guard let ident = entry["Display Identifier"] as? String, let display = resolveDisplay(ident) else { return nil }
            let current = (entry["Current Space"] as? [String: Any]).flatMap(spaceID)
            var index = 0
            var out: [SpaceInfo] = []
            for s in entry["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = spaceID(s) else { continue }
                switch intValue(s["type"]) ?? userType {
                case userType:
                    index += 1
                    out.append(SpaceInfo(id: id, display: display, kind: .user, index: index))
                case fullscreenType:
                    out.append(SpaceInfo(id: id, display: display, kind: .fullscreen, index: nil))
                default:
                    continue
                }
            }
            return ManagedDisplaySpaces(identifier: ident, display: display, currentSpace: current, spaces: out)
        }
    }

    static func spaceID(_ dict: [String: Any]) -> SpaceID? {
        if let v = uint64Value(dict["id64"]), v != 0 { return v }
        if let v = uint64Value(dict["ManagedSpaceID"]), v != 0 { return v }
        return nil
    }

    static func uint64Value(_ any: Any?) -> UInt64? {
        switch any {
        case let n as NSNumber: return n.uint64Value
        case let i as Int: return i >= 0 ? UInt64(i) : nil
        case let u as UInt64: return u
        case let i as Int64: return i >= 0 ? UInt64(i) : nil
        default: return nil
        }
    }

    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let i as Int: return i
        default: return nil
        }
    }
}
