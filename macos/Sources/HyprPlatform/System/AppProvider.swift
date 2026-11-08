import AppKit
import Foundation

/// Running applications.
public protocol AppProvider: AnyObject {
    func runningApplications() -> [AppInfo]
    func application(pid: pid_t) -> AppInfo?
}

public final class SystemAppProvider: AppProvider {
    public init() {}

    public func runningApplications() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap(Self.info)
    }

    public func application(pid: pid_t) -> AppInfo? {
        NSRunningApplication(processIdentifier: pid).flatMap(Self.info)
    }

    static func info(_ app: NSRunningApplication) -> AppInfo? {
        guard !app.isTerminated else { return nil }
        return AppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                       name: app.localizedName,
                       activationPolicy: ActivationPolicy(rawValue: app.activationPolicy.rawValue) ?? .prohibited,
                       isHidden: app.isHidden)
    }
}
