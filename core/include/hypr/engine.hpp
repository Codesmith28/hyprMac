#pragma once
// The tiling engine behind hypr_core.h, as a C++ class. c_api.cpp is a thin,
// exception-safe wrapper around it.
//
// Deterministic rules (where the contract leaves room):
//  * Duplicate window ids in one snapshot: the FIRST occurrence wins; later
//    entries with the same id are ignored.
//  * Validation happens before any mutation. Invalid input (space 0, window id
//    0, non-finite or |v| > 1e9 rects/min sizes, unknown state) returns
//    HM_ERR_INVALID_ARGUMENT and leaves the engine untouched.
//  * Reconcile order: (1) record display/usable and min-size hints, (2) remove
//    tree windows absent from the snapshot, (3) walk the snapshot front to back
//    removing windows that left the tree (FLOATING: no ghost; MINIMIZED/
//    FULLSCREEN/HIDDEN: ghost against the space that held them; TILED in another
//    space: no ghost), (4) restore this space's ghosts, newest ghost first (the
//    exact inverse of ghosting order), (5) dwindle-insert new windows back to
//    front (reverse snapshot order), (6) lay out.
//  * Ghost restore re-splits the largest subtree that contains the recorded
//    sibling leaf and consists only of windows that formed the sibling subtree
//    when the ghost was taken. With no intervening changes this reproduces the
//    original tree (and rectangles) exactly; it degrades to "re-split the
//    sibling leaf" when the sibling subtree changed.
//  * A ghost whose window shows up TILED in a DIFFERENT space's snapshot is
//    dropped and the window is dwindle-inserted there.
//  * A FLOATING window drops its ghost slot (it is visible and untiled).
//  * Dwindle target, evaluated before each insertion: the focused window if it
//    is a leaf of this space and not inserted in this reconcile; otherwise the
//    most recently inserted window of this space if it is still a leaf;
//    otherwise the front-most snapshot window that is a leaf; otherwise the
//    first leaf in tree order. Orientation uses the target's current computed
//    rectangle (with the snapshot's usable rect).
//  * Plan placements are in tree order (first child before second child).
//  * Min sizes are merged PER AXIS: a positive value replaces the stored one,
//    0 means "unknown on this axis" and keeps it (the executor reports only the
//    axis that overflowed). Layout uses the per-axis max of the snapshot hint
//    and the reported value. Re-reporting the same size changes nothing, so a
//    relayout after it yields identical geometry.
//  * resize: for each edge of `desired` that differs from the window's laid-out frame (> 0.5 pt),
//    the nearest ancestor split on that axis with the window in the SECOND child (left/top edge)
//    or FIRST child (right/bottom edge) gets ratio = (boundary - rect.start [- gap]) / (L - gap),
//    clamped to [0.1, 0.9] and to both subtrees' minimum sizes. Edges with no such split are
//    ignored (the plan snaps them back). Outermost splits are adjusted first.
//  * forget_space also drops the ghosts recorded against that space.
#include "hypr/bsp_layout.hpp"
#include "hypr/config.hpp"
#include "hypr/workspace_model.hpp"

#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace hypr {

enum class WindowState : std::uint8_t { Tiled, Floating, Minimized, Fullscreen, Hidden };

struct WindowInfo {
    WindowId id = 0;
    WindowState state = WindowState::Tiled;
    Rect frame;
    double min_w = 0, min_h = 0;
};

struct Snapshot {
    DisplayId display = 0;
    SpaceId space = 0;
    Rect usable;
    WindowId focused = 0;
    std::vector<WindowInfo> windows; // front to back
};

struct Plan {
    std::uint64_t revision = 0;
    SpaceId space = 0;
    std::vector<Placement> placements;
};

class Engine {
public:
    explicit Engine(const Config &cfg = {});

    const Config &config() const { return cfg_; }
    hm_status set_config(const Config &cfg); // HM_ERR_CONFIG when invalid

    // Gap policy on top of the config. smart_gaps: a space with exactly one tiled leaf uses zero inner
    // AND zero outer gap (its window fills the usable rect). Per-display gaps: a value >= 0 replaces the
    // global inner/outer gap for every space on that display (< 0 keeps the global one; both < 0 clears).
    // Neither changes dwindle orientation: insertion decisions use the un-smartened layout.
    void set_smart_gaps(bool on) { smart_gaps_ = on; }
    hm_status set_display_gaps(DisplayId display, double inner, double outer); // HM_ERR_CONFIG when out of range

    hm_status reconcile(const Snapshot &snapshot, Plan &out);
    hm_status relayout(SpaceId space, Plan &out);
    hm_status report_min_size(WindowId w, double min_w, double min_h);
    hm_status swap(WindowId a, WindowId b, Plan &out);
    // The user resized `w` to `desired`: move the adjacent split boundaries (see engine.cpp) and
    // return the plan for the window's space. HM_ERR_UNKNOWN_WINDOW unless `w` is a tiled leaf.
    hm_status resize(WindowId w, const Rect &desired, Plan &out);
    void forget_window(WindowId w);
    void forget_space(SpaceId space);

    SpaceId space_of(WindowId w) const { return model_.space_of(w); }
    std::size_t tiled_count(SpaceId space) const;
    std::string debug_dump(SpaceId space) const;

    // Introspection (tests, debugging).
    const WorkspaceModel &model() const { return model_; }
    MinSize min_size(WindowId w) const;
    LayoutResult layout_of(SpaceId space) const; // empty result for unknown spaces
    std::uint64_t last_revision() const { return revision_; }

private:
    struct MinInfo {
        MinSize hint;     // from snapshots
        MinSize reported; // from report_min_size
    };

    static hm_status validate(const Snapshot &s);
    LayoutResult layout(const Space &space, bool smart = true) const;
    Config effective_config(const Space &space, bool smart) const;
    void make_plan(const Space &space, Plan &out);
    void restore(Space &space, WindowId w, const Snapshot &s, const std::unordered_set<WindowId> &pending);
    void dwindle_insert(Space &space, WindowId w, const Snapshot &s, const std::unordered_set<WindowId> &pending);
    WindowId choose_target(const Space &space, const Snapshot &s,
                           const std::unordered_set<WindowId> &pending) const;
    void drop_if_untracked(WindowId w);

    Config cfg_;
    bool smart_gaps_ = false;
    std::unordered_map<DisplayId, std::pair<double, double>> display_gaps_; // (inner, outer), < 0 = unset
    WorkspaceModel model_;
    std::unordered_map<WindowId, MinInfo> mins_;
    std::uint64_t revision_ = 0;
};

namespace diag {
// Outstanding hm_plan placement buffers (malloc'd by the C API, released by hm_plan_free).
long live_plan_buffers();
} // namespace diag

} // namespace hypr
