import Foundation
import ApplicationServices

/// Private symbols resolved at runtime with dlsym (read-only use only).
enum Private {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ names: [String], _: T.Type) -> T? {
        for name in names {
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) ?? skyLight.flatMap({ dlsym($0, name) }) {
                return unsafeBitCast(p, to: T.self)
            }
        }
        return nil
    }

    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64

    static let axGetWindow = sym(["_AXUIElementGetWindow"], AXGetWindowFn.self)
    static let mainConnection = sym(["CGSMainConnectionID", "SLSMainConnectionID"], MainConnectionFn.self)
    static let copyManagedDisplaySpaces = sym(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"],
                                              CopyManagedDisplaySpacesFn.self)
    static let getActiveSpace = sym(["CGSGetActiveSpace", "SLSGetActiveSpace"], GetActiveSpaceFn.self)

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let f = axGetWindow else { return nil }
        var id: CGWindowID = 0
        return f(element, &id) == .success && id != 0 ? id : nil
    }
}
