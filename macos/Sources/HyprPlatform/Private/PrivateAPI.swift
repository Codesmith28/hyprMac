import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The ONLY file that touches private symbols.
///
/// Every symbol is resolved lazily with `dlsym` and is optional. Only **read-only** functions
/// are bound here: nothing in this file can mutate Spaces or windows.
public enum PrivateAPI {
    public typealias ConnectionID = Int32

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias GetActiveSpaceFn = @convention(c) (ConnectionID) -> UInt64
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias ManagedDisplayGetCurrentSpaceFn = @convention(c) (ConnectionID, CFString) -> UInt64

    private static let skyLight: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
        for name in names {
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return p } // RTLD_DEFAULT
            if let h = skyLight, let p = dlsym(h, name) { return p }
        }
        return nil
    }

    private static let getWindow: GetWindowFn? =
        symbol("_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindowFn.self) }
    private static let mainConnection: MainConnectionFn? =
        symbol("CGSMainConnectionID", "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnectionFn.self) }
    private static let getActiveSpace: GetActiveSpaceFn? =
        symbol("CGSGetActiveSpace", "SLSGetActiveSpace").map { unsafeBitCast($0, to: GetActiveSpaceFn.self) }
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? =
        symbol("CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces")
            .map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self) }
    private static let copySpacesForWindows: CopySpacesForWindowsFn? =
        symbol("CGSCopySpacesForWindows", "SLSCopySpacesForWindows")
            .map { unsafeBitCast($0, to: CopySpacesForWindowsFn.self) }
    private static let managedDisplayGetCurrentSpace: ManagedDisplayGetCurrentSpaceFn? =
        symbol("CGSManagedDisplayGetCurrentSpace", "SLSManagedDisplayGetCurrentSpace")
            .map { unsafeBitCast($0, to: ManagedDisplayGetCurrentSpaceFn.self) }

    private static let connection: ConnectionID? = mainConnection?()

    // MARK: availability

    /// `_AXUIElementGetWindow` resolved.
    public static var isWindowIDAvailable: Bool { getWindow != nil }
    /// All SkyLight read-only symbols needed for native Spaces resolved.
    public static var isSpacesAvailable: Bool {
        connection != nil && getActiveSpace != nil && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
    }
    public static var isManagedDisplayCurrentSpaceAvailable: Bool { managedDisplayGetCurrentSpace != nil }

    // MARK: calls (all read-only)

    /// `_AXUIElementGetWindow`.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindow else { return nil }
        var wid: CGWindowID = 0
        guard fn(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// `CGSGetActiveSpace` (the Space of the display with keyboard focus).
    public static func activeSpace() -> SpaceID? {
        guard let cid = connection, let fn = getActiveSpace else { return nil }
        let s = fn(cid)
        return s == 0 ? nil : s
    }

    /// `CGSCopyManagedDisplaySpaces`, bridged to Foundation.
    public static func managedDisplaySpaces() -> [[String: Any]]? {
        guard let cid = connection, let fn = copyManagedDisplaySpaces,
              let arr = fn(cid)?.takeRetainedValue() else { return nil }
        return arr as? [[String: Any]]
    }

    /// `CGSCopySpacesForWindows` with mask 0x7 (all Spaces).
    public static func spaces(forWindow id: CGWindowID) -> [SpaceID]? {
        guard let cid = connection, let fn = copySpacesForWindows else { return nil }
        let ids = [NSNumber(value: id)] as CFArray
        guard let arr = fn(cid, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return arr.map { $0.uint64Value }
    }

    /// `CGSManagedDisplayGetCurrentSpace` for a display identifier (UUID string or "Main").
    public static func currentSpace(displayIdentifier: String) -> SpaceID? {
        guard let cid = connection, let fn = managedDisplayGetCurrentSpace else { return nil }
        let s = fn(cid, displayIdentifier as CFString)
        return s == 0 ? nil : s
    }
}
