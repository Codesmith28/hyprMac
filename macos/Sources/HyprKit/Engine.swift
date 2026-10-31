import CHyprCore
import CoreGraphics
import Foundation

/// Swift wrapper around the C++ engine (`hm_engine`). Not thread-safe: use it from the
/// coordinator's serial queue only.
public final class Engine {
    public struct WindowEntry: Equatable {
        public var id: UInt64
        public var state: TileState
        public var frame: CGRect
        public var minSize: CGSize
        public init(id: UInt64, state: TileState, frame: CGRect = .zero, minSize: CGSize = .zero) {
            self.id = id; self.state = state; self.frame = frame; self.minSize = minSize
        }
    }

    public enum TileState: Equatable {
        case tiled, floating, minimized, fullscreen, hidden
        var c: hm_window_state {
            switch self {
            case .tiled: return HM_WINDOW_TILED
            case .floating: return HM_WINDOW_FLOATING
            case .minimized: return HM_WINDOW_MINIMIZED
            case .fullscreen: return HM_WINDOW_FULLSCREEN
            case .hidden: return HM_WINDOW_HIDDEN
            }
        }
    }

    public struct Plan: Equatable {
        public var revision: UInt64
        public var space: UInt64
        public var placements: [(id: UInt64, frame: CGRect)]
        public static func == (a: Plan, b: Plan) -> Bool {
            a.revision == b.revision && a.space == b.space && a.placements.count == b.placements.count
                && zip(a.placements, b.placements).allSatisfy { $0.id == $1.id && $0.frame == $1.frame }
        }
    }

    public enum EngineError: Error, Equatable { case status(UInt32) }

    private let handle: OpaquePointer

    public init(config: Config = .defaults) {
        var c = config.c
        guard let h = hm_engine_create(&c) else { fatalError("hm_engine_create failed") }
        handle = h
    }
    deinit { hm_engine_destroy(handle) }

    public func setConfig(_ config: Config) throws {
        var c = config.c
        try check(hm_engine_set_config(handle, &c))
    }

    public func reconcile(display: UInt32, space: UInt64, usable: CGRect, focused: UInt64?,
                          windows: [WindowEntry]) throws -> Plan {
        var infos = windows.map { w in
            hm_window_info(id: w.id, state: w.state.c, frame: hm_rect(w.frame),
                           min_w: Double(w.minSize.width), min_h: Double(w.minSize.height))
        }
        var plan = hm_plan()
        let status = infos.withUnsafeMutableBufferPointer { buf -> hm_status in
            var snap = hm_space_snapshot(display: display, space: space, usable: hm_rect(usable),
                                         focused: focused ?? 0, windows: buf.baseAddress,
                                         window_count: buf.count)
            return hm_engine_reconcile(handle, &snap, &plan)
        }
        defer { hm_plan_free(&plan) }
        try check(status)
        return Plan(plan)
    }

    public func relayout(space: UInt64) throws -> Plan {
        var plan = hm_plan()
        defer { hm_plan_free(&plan) }
        try check(hm_engine_relayout(handle, space, &plan))
        return Plan(plan)
    }

    public func reportMinSize(window: UInt64, size: CGSize) throws {
        try check(hm_engine_report_min_size(handle, window, Double(size.width), Double(size.height)))
    }

    public func forget(window: UInt64) { hm_engine_forget_window(handle, window) }
    public func forget(space: UInt64) { hm_engine_forget_space(handle, space) }
    public func space(of window: UInt64) -> UInt64? {
        let s = hm_engine_space_of(handle, window); return s == 0 ? nil : s
    }
    public func tiledCount(space: UInt64) -> Int { Int(hm_engine_tiled_count(handle, space)) }

    public func debugDump(space: UInt64) -> String {
        let n = hm_engine_debug_dump(handle, space, nil, 0)
        var buf = [CChar](repeating: 0, count: n + 1)
        _ = hm_engine_debug_dump(handle, space, &buf, buf.count)
        return String(cString: buf)
    }

    public static var version: String { String(cString: hm_version()) }

    private func check(_ s: hm_status) throws {
        if s != HM_OK { throw EngineError.status(s.rawValue) }
    }
}

extension hm_rect {
    init(_ r: CGRect) { self.init(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.width), h: Double(r.height)) }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

extension Engine.Plan {
    init(_ p: hm_plan) {
        revision = p.revision
        space = p.space
        placements = (0..<p.count).map { i in (p.placements[i].id, p.placements[i].frame.cg) }
    }
}
