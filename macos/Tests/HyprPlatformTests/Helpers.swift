import CoreGraphics
import Foundation
@testable import HyprPlatform

/// Thread-safe collector of executor reports.
final class ExecutorEvents: GeometryExecutorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ExecutorEvent] = []
    private var times: [(ExecutorEvent, TimeInterval)] = []

    func geometryExecutor(_ executor: GeometryExecutor, didReport event: ExecutorEvent) {
        lock.lock(); list.append(event); times.append((event, ProcessInfo.processInfo.systemUptime)); lock.unlock()
    }

    var all: [ExecutorEvent] { lock.lock(); defer { lock.unlock() }; return list }
    func firstTime(where match: (ExecutorEvent) -> Bool) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }; return times.first { match($0.0) }?.1
    }
}

extension ExecutorEvent {
    var ref: WindowRef {
        switch self {
        case .landed(let r, _, _, _), .minSizeDiscovered(let r, _), .mismatch(let r, _, _), .windowGone(let r), .failed(let r, _):
            return r
        }
    }
}

let mainFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
let mainVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)

/// One 1440×900 main display (id 1) with `spaces` user Spaces and a regular app (pid 100).
func makeDesk(spaces: Int = 3) -> FakeDesktop {
    let desk = FakeDesktop(sleeper: { Thread.sleep(forTimeInterval: $0) })
    desk.addDisplay(1, frame: mainFrame, visibleFrame: mainVisible, isMain: true, userSpaces: spaces)
    desk.addApp(pid: 100, bundleID: "com.example.editor")
    return desk
}

func makeExecutor(_ desk: FakeDesktop, retryDelays: [TimeInterval] = [0.01, 0.02]) -> (GeometryExecutor, ExecutorEvents) {
    var cfg = GeometryExecutor.Configuration()
    cfg.retryDelays = retryDelays
    let ex = GeometryExecutor(ax: desk.ax, clock: desk.clock, configuration: cfg)
    let events = ExecutorEvents()
    ex.delegate = events
    return (ex, events)
}

func makeDiscovery(_ desk: FakeDesktop) -> WindowDiscovery {
    WindowDiscovery(ax: desk.ax, windowServer: desk.windowServer, spaces: desk.spaces,
                    displays: desk.displays, apps: desk.apps)
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
