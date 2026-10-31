import CHyprCore
import CoreGraphics
import Foundation

/// Swift wrapper around the C++ engine (`hm_engine`). Not thread-safe: use it from the
/// coordinator's serial queue only.
///
/// Boundary rules:
/// - Every `hm_plan` is freed with `hm_plan_free` on all paths (success and error) after
///   its placements have been copied into Swift values; no C pointer escapes this file.
/// - Informational inputs (window frames, minimum sizes) are sanitised before crossing the
///   boundary: the core rejects a whole snapshot when any rect or size is non-finite or
///   larger than 1e9, so a single garbage AX value must not stop tiling for a Space.
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

    /// `hm_status` codes as Swift errors.
    public enum EngineError: Error, Equatable {
        case invalidArgument
        case unknownSpace
        case unknownWindow
        case config
        case internalError
        /// A code this wrapper doesn't know (newer core).
        case status(UInt32)

        init(_ s: hm_status) {
            switch s {
            case HM_ERR_INVALID_ARGUMENT: self = .invalidArgument
            case HM_ERR_UNKNOWN_SPACE: self = .unknownSpace
            case HM_ERR_UNKNOWN_WINDOW: self = .unknownWindow
            case HM_ERR_CONFIG: self = .config
            case HM_ERR_INTERNAL: self = .internalError
            default: self = .status(s.rawValue)
            }
        }
    }

    /// Largest magnitude the core accepts (`hypr::kMaxCoordinate`).
    static let maxCoordinate = 1e9

    private let handle: OpaquePointer
    /// Last minimum size reported per window, merged per axis exactly like the core does
    /// (a positive value replaces that axis, 0 keeps it). Used to tell callers whether a
    /// report changed anything, so they can skip a pointless relayout.
    private var reportedMinSizes: [UInt64: CGSize] = [:]

    /// An invalid `config` falls back to the built-in defaults instead of crashing; use
    /// `setConfig` (which throws) to validate one. Only allocation failure is fatal.
    public init(config: Config = .defaults) {
        var c = config.c
        if let h = hm_engine_create(&c) {
            handle = h
        } else if let h = hm_engine_create(nil) {
            handle = h
        } else {
            fatalError("hm_engine_create failed (out of memory)")
        }
    }
    deinit { hm_engine_destroy(handle) }

    public func setConfig(_ config: Config) throws {
        var c = config.c
        try check(hm_engine_set_config(handle, &c))
    }

    public func reconcile(display: UInt32, space: UInt64, usable: CGRect, focused: UInt64?,
                          windows: [WindowEntry]) throws -> Plan {
        let infos = windows.map { w in
            hm_window_info(id: w.id, state: w.state.c, frame: hm_rect(Self.sanitized(w.frame)),
                           min_w: Self.sanitizedMin(w.minSize.width), min_h: Self.sanitizedMin(w.minSize.height))
        }
        var plan = hm_plan()
        defer { hm_plan_free(&plan) }
        let status = infos.withUnsafeBufferPointer { buf -> hm_status in
            var snap = hm_space_snapshot(display: display, space: space, usable: hm_rect(usable),
                                         focused: focused ?? 0, windows: buf.baseAddress,
                                         window_count: buf.count)
            return hm_engine_reconcile(handle, &snap, &plan)
        }
        try check(status)
        return Plan(plan)
    }

    public func relayout(space: UInt64) throws -> Plan {
        var plan = hm_plan()
        defer { hm_plan_free(&plan) }
        try check(hm_engine_relayout(handle, space, &plan))
        return Plan(plan)
    }

    /// The user resized `window` to `desired`: adopts the new edges by moving the adjacent split
    /// ratios and returns the plan for the window's Space. Throws `.unknownWindow` unless the window
    /// is tiled, `.invalidArgument` for a non-finite rect.
    public func resize(window: UInt64, desired: CGRect) throws -> Plan {
        var plan = hm_plan()
        defer { hm_plan_free(&plan) }
        try check(hm_engine_resize(handle, window, hm_rect(desired), &plan))
        return Plan(plan)
    }

    /// Records a minimum size discovered by read-back (0 on an axis = unknown, keeps the
    /// previous value). Throws `.unknownWindow` for windows the engine doesn't hold.
    public func reportMinSize(window: UInt64, size: CGSize) throws {
        _ = try reportMinSizeChanged(window: window, size: size)
    }

    /// Like `reportMinSize`, but returns `true` only when the stored minimum changed, i.e.
    /// when a relayout can produce different geometry. Callers should skip the relayout on
    /// `false`: re-reporting an unsatisfiable minimum otherwise loops
    /// write → read-back → report → relayout → write.
    public func reportMinSizeChanged(window: UInt64, size: CGSize) throws -> Bool {
        let w = Self.sanitizedMin(size.width), h = Self.sanitizedMin(size.height)
        do {
            try check(hm_engine_report_min_size(handle, window, w, h))
        } catch {
            reportedMinSizes[window] = nil
            throw error
        }
        let old = reportedMinSizes[window] ?? .zero
        let merged = CGSize(width: w > 0 ? w : old.width, height: h > 0 ? h : old.height)
        reportedMinSizes[window] = merged
        return merged != old
    }

    public func forget(window: UInt64) {
        hm_engine_forget_window(handle, window)
        reportedMinSizes[window] = nil
    }
    public func forget(space: UInt64) { hm_engine_forget_space(handle, space) }
    public func space(of window: UInt64) -> UInt64? {
        let s = hm_engine_space_of(handle, window); return s == 0 ? nil : s
    }
    public func tiledCount(space: UInt64) -> Int { Int(hm_engine_tiled_count(handle, space)) }

    public func debugDump(space: UInt64) -> String {
        let needed = hm_engine_debug_dump(handle, space, nil, 0)
        guard needed > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: needed + 1)
        let written = buf.withUnsafeMutableBufferPointer { hm_engine_debug_dump(handle, space, $0.baseAddress, $0.count) }
        let length = min(needed, written)
        return String(decoding: buf.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static var version: String { String(cString: hm_version()) }

    private func check(_ s: hm_status) throws {
        if s != HM_OK { throw EngineError(s) }
    }

    // MARK: sanitising

    private static func isUsable(_ v: CGFloat) -> Bool { v.isFinite && abs(Double(v)) <= maxCoordinate }

    /// Frames are informational for the core; anything it would reject becomes `.zero`.
    static func sanitized(_ r: CGRect) -> CGRect {
        [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(isUsable) ? r : .zero
    }

    /// Minimum sizes: non-finite, negative or absurd values mean "unknown" (0).
    static func sanitizedMin(_ v: CGFloat) -> Double { isUsable(v) && v > 0 ? Double(v) : 0 }
}

extension hm_rect {
    /// Raw origin and size (not `minX`/`width`, which standardise only one half of a
    /// rect with a negative size).
    init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.size.width), h: Double(r.size.height))
    }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

extension Engine.Plan {
    /// Copies the placements out of a C plan (the caller still frees it).
    init(_ p: hm_plan) {
        revision = p.revision
        space = p.space
        placements = UnsafeBufferPointer(start: p.placements, count: p.count).map { ($0.id, $0.frame.cg) }
    }
}
