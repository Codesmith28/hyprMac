#include "hypr/bsp_layout.hpp"

#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace hypr {

namespace {

constexpr double kLeafFloor = 1.0;

struct Need {
    double min_w = 0, min_h = 0;     // user minimums (window min sizes + gaps)
    double floor_w = 0, floor_h = 0; // structural floor: 1 pt per leaf, no gaps
};

double sanitize_min(double v) { return (std::isfinite(v) && v > 0) ? std::min(v, kMaxCoordinate) : 0.0; }

class Layouter {
public:
    Layouter(const Config &cfg, const MinSizeLookup &lookup, LayoutResult &out)
        : cfg_(cfg), lookup_(lookup), out_(out) {}

    Need measure(const Node *n) {
        Need need;
        if (n->is_leaf()) {
            if (lookup_) {
                const MinSize m = lookup_(n->window);
                need.min_w = sanitize_min(m.w);
                need.min_h = sanitize_min(m.h);
            }
            need.floor_w = need.floor_h = kLeafFloor;
            // A leaf always needs at least its floor, so subtree minimums (sums along an axis)
            // account for every sibling's 1 pt and a satisfiable nest is never reported short.
            need.min_w = std::max(need.min_w, kLeafFloor);
            need.min_h = std::max(need.min_h, kLeafFloor);
        } else {
            const Need a = measure(n->child[0].get());
            const Need b = measure(n->child[1].get());
            const double g = cfg_.inner_gap;
            if (n->orientation == Orientation::Vertical) {
                need.min_w = a.min_w + b.min_w + g;
                need.min_h = std::max(a.min_h, b.min_h);
                need.floor_w = a.floor_w + b.floor_w;
                need.floor_h = std::max(a.floor_h, b.floor_h);
            } else {
                need.min_h = a.min_h + b.min_h + g;
                need.min_w = std::max(a.min_w, b.min_w);
                need.floor_h = a.floor_h + b.floor_h;
                need.floor_w = std::max(a.floor_w, b.floor_w);
            }
        }
        needs_[n] = need;
        return need;
    }

    void place(const Node *n, const Rect &r) {
        if (n->is_leaf()) {
            Rect f = r;
            if (!(f.w >= kLeafFloor)) {
                f.w = kLeafFloor;
                out_.degenerate = true;
            }
            if (!(f.h >= kLeafFloor)) {
                f.h = kLeafFloor;
                out_.degenerate = true;
            }
            out_.placements.push_back({n->window, f});
            return;
        }
        const Node *c0 = n->child[0].get();
        const Node *c1 = n->child[1].get();
        const Need &a = needs_.at(c0);
        const Need &b = needs_.at(c1);
        const bool vertical = n->orientation == Orientation::Vertical;
        const double length = vertical ? r.w : r.h;
        double l1 = 0, gap = 0, l2 = 0;
        if (vertical)
            split(length, n->ratio, a.min_w, b.min_w, a.floor_w, b.floor_w, l1, gap, l2);
        else
            split(length, n->ratio, a.min_h, b.min_h, a.floor_h, b.floor_h, l1, gap, l2);

        if (vertical) {
            out_.gap_area += gap * r.h;
            place(c0, {r.x, r.y, l1, r.h});
            place(c1, {r.x + l1 + gap, r.y, l2, r.h});
        } else {
            out_.gap_area += gap * r.w;
            place(c0, {r.x, r.y, r.w, l1});
            place(c1, {r.x, r.y + l1 + gap, r.w, l2});
        }
    }

private:
    void split(double length, double ratio, double min1, double min2, double floor1, double floor2, double &l1,
               double &gap, double &l2) {
        gap = cfg_.inner_gap;
        if (length - gap < floor1 + floor2) {
            gap = std::max(0.0, length - floor1 - floor2);
            out_.degenerate = true;
        }
        const double avail = length - gap;
        const double m1 = std::max(min1, floor1);
        const double m2 = std::max(min2, floor2);
        l1 = avail * ratio;
        if (m1 + m2 <= avail) {
            if (l1 < m1)
                l1 = m1;
            else if (avail - l1 < m2)
                l1 = avail - m2;
        } else if (avail >= floor1 + floor2) {
            // Unsatisfiable minimums: divide in proportion and accept the shortfall,
            // but never below the structural floors.
            l1 = std::clamp(avail * m1 / (m1 + m2), floor1, avail - floor2);
        } else {
            // Not even the 1 pt floors fit (already flagged degenerate).
            l1 = avail * floor1 / (floor1 + floor2);
        }
        l2 = avail - l1;
    }

    const Config &cfg_;
    const MinSizeLookup &lookup_;
    LayoutResult &out_;
    std::unordered_map<const Node *, Need> needs_;
};

} // namespace

Rect root_rect(const Rect &usable, double outer_gap, bool *clamped) {
    Rect r = inset(usable, outer_gap);
    bool c = false;
    if (!(r.w >= kLeafFloor)) {
        r.w = kLeafFloor;
        r.x = usable.x + usable.w / 2 - kLeafFloor / 2;
        c = true;
    }
    if (!(r.h >= kLeafFloor)) {
        r.h = kLeafFloor;
        r.y = usable.y + usable.h / 2 - kLeafFloor / 2;
        c = true;
    }
    if (clamped) *clamped = c;
    return r;
}

Orientation dwindle_orientation(const Rect &leaf) {
    return leaf.w >= leaf.h ? Orientation::Vertical : Orientation::Horizontal;
}

LayoutResult compute_layout(const LayoutTree &tree, const Rect &usable, const Config &cfg,
                            const MinSizeLookup &min_size) {
    LayoutResult out;
    bool clamped = false;
    out.root = root_rect(usable, cfg.outer_gap, &clamped);
    out.degenerate = clamped;
    if (tree.empty()) return out;
    out.placements.reserve(tree.leaf_count());
    Layouter l(cfg, min_size, out);
    l.measure(tree.root());
    l.place(tree.root(), out.root);
    return out;
}

std::optional<Rect> find_frame(const LayoutResult &layout, WindowId w) {
    for (const auto &p : layout.placements)
        if (p.id == w) return p.frame;
    return std::nullopt;
}

} // namespace hypr
