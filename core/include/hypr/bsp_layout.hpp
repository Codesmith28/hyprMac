#pragma once
// Geometry for a LayoutTree: gaps, min-size constraints, degenerate clamping.
//
// Gap rule: R = usable inset by outer_gap. A split of length L along its axis
// gives L1 = (L - g) * ratio and L2 = L - g - L1 (g = inner_gap). Gaps are local
// to each split; leaves are never inset individually.
//
// Min sizes: a leaf's minimum is the window's (w, h) minimum. A subtree's
// minimum along its split axis is min1 + min2 + g, across it max(min1, min2).
// When a child's share is below its minimum and both fit (L - g >= min1 + min2)
// the effective split is shifted (the stored ratio is never mutated). When they
// cannot both fit, L - g is divided in proportion to the minimums.
//
// Degenerate inputs (tiny screens, huge gaps): every leaf has a structural floor
// of 1x1 pt. If a split cannot hold the floors of both children plus the gap,
// the gap at that split shrinks (down to 0) so tiles keep >= 1 pt and never
// overlap. If R itself is smaller than 1 pt it is clamped to 1 pt, centred on
// the usable rect. Leaves are finally clamped to >= 1x1. Such layouts are
// flagged `degenerate`. NaN or negative sizes are never produced.
#include "hypr/config.hpp"
#include "hypr/geometry.hpp"
#include "hypr/layout_tree.hpp"

#include <functional>
#include <optional>
#include <vector>

namespace hypr {

struct MinSize {
    double w = 0, h = 0;
};
using MinSizeLookup = std::function<MinSize(WindowId)>;

struct Placement {
    WindowId id = 0;
    Rect frame;
};

struct LayoutResult {
    Rect root;                         // usable inset by outer gap (after clamping)
    std::vector<Placement> placements; // tree order
    double gap_area = 0;               // area occupied by inner gaps actually used
    bool degenerate = false;           // a gap was shrunk or a size was clamped
};

// usable inset by outer_gap; each axis clamped to >= 1 (centred) when needed.
Rect root_rect(const Rect &usable, double outer_gap, bool *clamped = nullptr);

// Dwindle: Vertical (side by side) if w >= h, otherwise Horizontal. Ties are Vertical.
Orientation dwindle_orientation(const Rect &leaf);

LayoutResult compute_layout(const LayoutTree &tree, const Rect &usable, const Config &cfg,
                            const MinSizeLookup &min_size = {});

std::optional<Rect> find_frame(const LayoutResult &layout, WindowId w);

} // namespace hypr
