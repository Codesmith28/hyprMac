#pragma once
// Layout-level helpers for the core tests.
#include "test_support.hpp"

#include "hypr/bsp_layout.hpp"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace hypr::test {

inline Rect frame(const LayoutResult &l, WindowId w) {
    auto f = find_frame(l, w);
    REQUIRE_MESSAGE(f.has_value(), "window " << w << " not in layout");
    return *f;
}

inline Rect bbox(const Node *n, const LayoutResult &l) {
    std::vector<WindowId> ws;
    LayoutTree::collect(n, ws);
    Rect b = *find_frame(l, ws.front());
    for (WindowId w : ws) {
        const Rect f = *find_frame(l, w);
        const double x0 = std::min(b.x, f.x), y0 = std::min(b.y, f.y);
        const double x1 = std::max(b.right(), f.right()), y1 = std::max(b.bottom(), f.bottom());
        b = {x0, y0, x1 - x0, y1 - y0};
    }
    return b;
}

// Gap area derived independently from the placed tiles: every split contributes
// inner_gap x (its extent across the split axis).
inline double expected_gap_area(const Node *n, const LayoutResult &l, double gap) {
    if (!n || n->is_leaf()) return 0.0;
    const Rect b = bbox(n, l);
    return gap * (n->orientation == Orientation::Vertical ? b.h : b.w) + expected_gap_area(n->child[0].get(), l, gap) +
           expected_gap_area(n->child[1].get(), l, gap);
}

// Geometric soundness of a layout; returns a description of the first failure.
inline std::string layout_problem(const LayoutResult &l, const Rect &usable, double outer_gap) {
    const Rect inner = inset(usable, outer_gap);
    double sum = 0;
    for (std::size_t i = 0; i < l.placements.size(); ++i) {
        const Rect f = l.placements[i].frame;
        if (!is_valid_rect(f)) return "non-finite frame " + to_string(f);
        if (!(f.w > 0 && f.h > 0)) return "non-positive frame " + to_string(f);
        if (!contains(inner, f)) return "frame " + to_string(f) + " outside " + to_string(inner);
        for (std::size_t j = i + 1; j < l.placements.size(); ++j)
            if (intersection_area(f, l.placements[j].frame) > 1e-6)
                return "overlap " + to_string(f) + " / " + to_string(l.placements[j].frame);
        sum += f.area();
    }
    if (!l.placements.empty() && std::fabs(sum + l.gap_area - l.root.area()) > 1e-6)
        return "area mismatch: tiles " + std::to_string(sum) + " + gaps " + std::to_string(l.gap_area) +
               " != " + std::to_string(l.root.area());
    return {};
}

} // namespace hypr::test
