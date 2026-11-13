#include "hypr/engine.hpp"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cmath>
#include <functional>
#include <optional>

namespace hypr {

namespace {

bool valid_min(double v) { return is_valid_scalar(v); }

// Per axis: a positive value replaces the stored one, 0 (or negative) means
// "unknown on this axis" and keeps it. The executor reports only the axis
// that overflowed, so a later report must not erase the other axis.
void merge_min(MinSize &into, double w, double h) {
    if (w > 0) into.w = w;
    if (h > 0) into.h = h;
}

bool is_valid_frame(const Rect &r) {
    return is_valid_rect(r) && r.w > 0 && r.h > 0;
}

bool frames_identical(const Rect &a, const Rect &b) {
    return std::abs(a.x - b.x) <= 0.5 &&
           std::abs(a.y - b.y) <= 0.5 &&
           std::abs(a.w - b.w) <= 0.5 &&
           std::abs(a.h - b.h) <= 0.5;
}

bool pairwise_precedes(const Rect &a, std::size_t a_idx,
                       const Rect &b, std::size_t b_idx) {
    if (!is_valid_frame(a) || !is_valid_frame(b) || frames_identical(a, b)) {
        return a_idx > b_idx;
    }

    const double overlap_y = std::max(0.0, std::min(a.bottom(), b.bottom()) - std::max(a.y, b.y));
    const double min_h = std::min(a.h, b.h);
    const bool substantial_overlap = (min_h > 0 && overlap_y >= 0.5 * min_h);

    if (substantial_overlap) {
        if (std::abs(a.x - b.x) > 0.5) return a.x < b.x;
        if (std::abs(a.y - b.y) > 0.5) return a.y < b.y;
    } else {
        if (std::abs(a.y - b.y) > 0.5) return a.y < b.y;
        if (std::abs(a.x - b.x) > 0.5) return a.x < b.x;
    }

    return a_idx > b_idx;
}

} // namespace

Engine::Engine(const Config &cfg) : cfg_(cfg) {}

hm_status Engine::set_config(const Config &cfg) {
    if (!hypr::validate(cfg).empty()) return HM_ERR_CONFIG;
    cfg_ = cfg;
    return HM_OK;
}

hm_status Engine::validate(const Snapshot &s) {
    if (s.space == 0 || !is_valid_rect(s.usable)) return HM_ERR_INVALID_ARGUMENT;
    for (const WindowInfo &w : s.windows) {
        if (w.id == 0) return HM_ERR_INVALID_ARGUMENT;
        if (static_cast<unsigned>(w.state) > static_cast<unsigned>(WindowState::Hidden))
            return HM_ERR_INVALID_ARGUMENT;
        if (!is_valid_rect(w.frame) || !valid_min(w.min_w) || !valid_min(w.min_h)) return HM_ERR_INVALID_ARGUMENT;
    }
    return HM_OK;
}

MinSize Engine::min_size(WindowId w) const {
    auto it = mins_.find(w);
    if (it == mins_.end()) return {};
    return {std::max(it->second.hint.w, it->second.reported.w), std::max(it->second.hint.h, it->second.reported.h)};
}

hm_status Engine::set_display_gaps(DisplayId display, double inner, double outer) {
    auto ok = [](double v) { return !std::isnan(v) && (v < 0 || v <= kMaxGap); };
    if (!ok(inner) || !ok(outer)) return HM_ERR_CONFIG;
    if (inner < 0 && outer < 0)
        display_gaps_.erase(display);
    else
        display_gaps_[display] = {inner, outer};
    return HM_OK;
}

Config Engine::effective_config(const Space &space, bool smart) const {
    Config c = cfg_;
    if (auto it = display_gaps_.find(space.display); it != display_gaps_.end()) {
        if (it->second.first >= 0) c.inner_gap = it->second.first;
        if (it->second.second >= 0) c.outer_gap = it->second.second;
    }
    if (smart && smart_gaps_ && space.tree.leaf_count() == 1) c.inner_gap = c.outer_gap = 0;
    return c;
}

LayoutResult Engine::layout(const Space &space, bool smart) const {
    return compute_layout(space.tree, space.usable, effective_config(space, smart),
                          [this](WindowId w) { return min_size(w); });
}

LayoutResult Engine::layout_of(SpaceId id) const {
    const Space *space = model_.find_space(id);
    return space ? layout(*space) : LayoutResult{};
}

void Engine::make_plan(const Space &space, Plan &out) {
    LayoutResult l = layout(space);
    Plan p;
    p.space = space.id;
    p.placements = std::move(l.placements);
    p.revision = ++revision_;
    out = std::move(p);
}

void Engine::drop_if_untracked(WindowId w) {
    if (model_.space_of(w) == 0) mins_.erase(w);
}

WindowId Engine::choose_target(const Space &space, const Snapshot &s,
                               const std::unordered_set<WindowId> &pending) const {
    const LayoutTree &t = space.tree;
    if (s.focused != 0 && !pending.count(s.focused) && t.contains(s.focused)) return s.focused;
    if (space.last_inserted != 0 && t.contains(space.last_inserted)) return space.last_inserted;
    for (const WindowInfo &w : s.windows)
        if (t.contains(w.id)) return w.id;
    return LayoutTree::first_leaf(t.root());
}

void Engine::dwindle_insert(Space &space, WindowId w, const Snapshot &s,
                            const std::unordered_set<WindowId> &pending) {
    if (space.tree.empty()) {
        model_.insert_root(space, w);
        return;
    }
    const WindowId target = choose_target(space, s, pending);
    const LayoutResult l = layout(space, false);
    const Rect r = find_frame(l, target).value_or(l.root);
    model_.split_leaf(space, target, w, dwindle_orientation(r), cfg_.split_ratio, false);
}

void Engine::restore(Space &space, WindowId w, const Snapshot &s, const std::unordered_set<WindowId> &pending) {
    const Ghost g = *model_.ghost(w);
    model_.drop_ghost(w);
    if (g.sibling != 0) {
        if (const Node *node = space.tree.find(g.sibling)) {
            const std::unordered_set<WindowId> allowed(g.sibling_subtree.begin(), g.sibling_subtree.end());
            auto all_allowed = [&](const Node *n) {
                std::vector<WindowId> ws;
                LayoutTree::collect(n, ws);
                return std::all_of(ws.begin(), ws.end(), [&](WindowId x) { return allowed.count(x) != 0; });
            };
            while (node->parent && all_allowed(node->parent)) node = node->parent;
            model_.wrap(space, node, w, g.orientation, g.ratio, g.was_first);
            return;
        }
    }
    dwindle_insert(space, w, s, pending);
}

hm_status Engine::reconcile(const Snapshot &s, Plan &out) {
    if (hm_status st = validate(s); st != HM_OK) return st;

    // First occurrence of each id wins.
    Snapshot snap;
    snap.display = s.display;
    snap.space = s.space;
    snap.usable = s.usable;
    snap.focused = s.focused;
    snap.windows.reserve(s.windows.size());
    {
        std::unordered_set<WindowId> seen;
        for (const WindowInfo &w : s.windows)
            if (seen.insert(w.id).second) snap.windows.push_back(w);
    }

    Space &space = model_.upsert_space(snap.space, snap.display, snap.usable);

    for (const WindowInfo &w : snap.windows) {
        if (w.min_w > 0 || w.min_h > 0) merge_min(mins_[w.id].hint, w.min_w, w.min_h);
    }

    // Tree windows absent from the snapshot are gone for good.
    {
        std::unordered_set<WindowId> present;
        for (const WindowInfo &w : snap.windows) present.insert(w.id);
        for (WindowId w : space.tree.windows()) {
            if (present.count(w)) continue;
            model_.remove(w, false);
            drop_if_untracked(w);
        }
    }

    std::vector<WindowId> restores;
    std::vector<WindowId> inserts;
    for (const WindowInfo &w : snap.windows) {
        const SpaceId in_tree = model_.tree_space_of(w.id);
        switch (w.state) {
        case WindowState::Tiled:
            if (in_tree == snap.space) break;
            if (in_tree != 0) {
                model_.remove(w.id, false); // moved from another space
                inserts.push_back(w.id);
            } else if (const Ghost *g = model_.ghost(w.id)) {
                if (g->space == snap.space) {
                    restores.push_back(w.id);
                } else {
                    model_.drop_ghost(w.id);
                    inserts.push_back(w.id);
                }
            } else {
                inserts.push_back(w.id);
            }
            break;
        case WindowState::Floating:
            if (in_tree != 0) model_.remove(w.id, false);
            model_.drop_ghost(w.id);
            break;
        case WindowState::Minimized:
        case WindowState::Fullscreen:
        case WindowState::Hidden:
            if (in_tree != 0) model_.remove(w.id, true);
            break;
        }
    }

    std::unordered_set<WindowId> pending(restores.begin(), restores.end());
    pending.insert(inserts.begin(), inserts.end());

    std::sort(restores.begin(), restores.end(),
              [this](WindowId a, WindowId b) { return model_.ghost(a)->seq > model_.ghost(b)->seq; });
    for (WindowId w : restores) restore(space, w, snap, pending);

    if (space.tree.empty() && inserts.size() > 1) {
        std::unordered_map<WindowId, Rect> frames;
        frames.reserve(snap.windows.size());
        for (const WindowInfo &w : snap.windows) {
            frames.emplace(w.id, w.frame);
        }

        const std::size_t n = inserts.size();
        std::vector<int> scores(n, 0);
        for (std::size_t i = 0; i < n; ++i) {
            const Rect &r_i = frames[inserts[i]];
            for (std::size_t j = 0; j < n; ++j) {
                if (i != j) {
                    const Rect &r_j = frames[inserts[j]];
                    if (pairwise_precedes(r_i, i, r_j, j)) {
                        scores[i]++;
                    }
                }
            }
        }

        std::vector<std::size_t> order(n);
        for (std::size_t i = 0; i < n; ++i) order[i] = i;

        std::sort(order.begin(), order.end(), [&](std::size_t i, std::size_t j) {
            if (scores[i] != scores[j]) return scores[i] > scores[j];
            return i > j;
        });

        for (std::size_t idx : order) {
            dwindle_insert(space, inserts[idx], snap, pending);
        }
    } else {
        for (auto it = inserts.rbegin(); it != inserts.rend(); ++it) dwindle_insert(space, *it, snap, pending);
    }

    for (const WindowInfo &w : snap.windows) drop_if_untracked(w.id);

    make_plan(space, out);
    return HM_OK;
}

hm_status Engine::relayout(SpaceId id, Plan &out) {
    const Space *space = model_.find_space(id);
    if (!space) return HM_ERR_UNKNOWN_SPACE;
    make_plan(*space, out);
    return HM_OK;
}

hm_status Engine::report_min_size(WindowId w, double min_w, double min_h) {
    if (w == 0 || !valid_min(min_w) || !valid_min(min_h) || min_w < 0 || min_h < 0) return HM_ERR_INVALID_ARGUMENT;
    if (model_.space_of(w) == 0) return HM_ERR_UNKNOWN_WINDOW;
    merge_min(mins_[w].reported, min_w, min_h);
    return HM_OK;
}

hm_status Engine::swap(WindowId a, WindowId b, Plan &out) {
    if (a == 0 || b == 0) return HM_ERR_INVALID_ARGUMENT;
    const SpaceId sa = model_.tree_space_of(a);
    const SpaceId sb = model_.tree_space_of(b);
    if (sa == 0 || sb == 0) return HM_ERR_UNKNOWN_WINDOW;
    if (sa != sb) return HM_ERR_INVALID_ARGUMENT;
    model_.swap(a, b);
    make_plan(*model_.find_space(sa), out);
    return HM_OK;
}

namespace {

Rect subtree_rect(const LayoutResult &l, const Node *n) {
    std::vector<WindowId> ids;
    LayoutTree::collect(n, ids);
    double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
    for (WindowId id : ids) {
        if (auto f = find_frame(l, id)) {
            x0 = std::min(x0, f->x);
            y0 = std::min(y0, f->y);
            x1 = std::max(x1, f->right());
            y1 = std::max(y1, f->bottom());
        }
    }
    return {x0, y0, x1 - x0, y1 - y0};
}

} // namespace

hm_status Engine::resize(WindowId w, const Rect &desired, Plan &out) {
    if (w == 0 || !is_valid_rect(desired)) return HM_ERR_INVALID_ARGUMENT;
    const SpaceId sid = model_.tree_space_of(w);
    if (sid == 0) return HM_ERR_UNKNOWN_WINDOW;
    Space *space = model_.find_space(sid);
    if (!space) return HM_ERR_UNKNOWN_WINDOW;

    constexpr double kEdgeEps = 0.5;
    const std::optional<Rect> cur = find_frame(layout(*space), w);
    if (!cur) return HM_ERR_UNKNOWN_WINDOW;

    // 0 = left, 1 = right (vertical splits); 2 = top, 3 = bottom (horizontal splits).
    struct Task {
        const Node *split;
        int edge;
        int depth;
    };
    std::vector<Task> tasks;
    for (int edge = 0; edge < 4; ++edge) {
        const bool vertical = edge < 2;
        const double now = edge == 0 ? cur->x : edge == 1 ? cur->right() : edge == 2 ? cur->y : cur->bottom();
        const double want = edge == 0   ? desired.x
                            : edge == 1 ? desired.right()
                            : edge == 2 ? desired.y
                                        : desired.bottom();
        if (std::abs(want - now) <= kEdgeEps) continue;
        const bool want_second = edge == 0 || edge == 2; // left/top edge: window in the SECOND child
        const Orientation o = vertical ? Orientation::Vertical : Orientation::Horizontal;
        const Node *child = space->tree.find(w);
        for (const Node *p = child->parent; p; child = p, p = p->parent) {
            if (p->orientation != o) continue;
            if ((p->child[want_second ? 1 : 0].get()) == child) break;
        }
        const Node *split = child ? child->parent : nullptr;
        if (!split) continue;
        int depth = 0;
        for (const Node *p = split; p->parent; p = p->parent) ++depth;
        tasks.push_back({split, edge, depth});
    }
    std::sort(tasks.begin(), tasks.end(), [](const Task &a, const Task &b) { return a.depth < b.depth; });

    const double g = effective_config(*space, false).inner_gap;
    std::function<MinSize(const Node *)> min_of = [&](const Node *n) -> MinSize {
        if (n->is_leaf()) {
            const MinSize m = min_size(n->window);
            return {std::max(m.w, 1.0), std::max(m.h, 1.0)};
        }
        const MinSize a = min_of(n->child[0].get());
        const MinSize b = min_of(n->child[1].get());
        if (n->orientation == Orientation::Vertical) return {a.w + b.w + g, std::max(a.h, b.h)};
        return {std::max(a.w, b.w), a.h + b.h + g};
    };

    for (const Task &t : tasks) {
        const LayoutResult l = layout(*space); // earlier tasks may have moved this split's rect
        const Rect r = subtree_rect(l, t.split);
        const bool vertical = t.edge < 2;
        const double start = vertical ? r.x : r.y;
        const double length = vertical ? r.w : r.h;
        const double avail = length - g;
        if (!(avail > 0)) continue;
        const double boundary = t.edge == 0   ? desired.x
                                : t.edge == 1 ? desired.right()
                                : t.edge == 2 ? desired.y
                                              : desired.bottom();
        // Right/bottom edge: the first child ends at the boundary; left/top: the second child starts there.
        double l1 = (t.edge == 1 || t.edge == 3) ? boundary - start : boundary - g - start;
        l1 = std::clamp(l1, avail * kMinRatio, avail * kMaxRatio);
        const MinSize m1 = min_of(t.split->child[0].get());
        const MinSize m2 = min_of(t.split->child[1].get());
        const double lo = vertical ? m1.w : m1.h;
        const double hi = avail - (vertical ? m2.w : m2.h);
        if (lo <= hi) l1 = std::clamp(l1, lo, hi);
        space->tree.set_ratio(t.split, l1 / avail);
    }

    make_plan(*space, out);
    return HM_OK;
}

void Engine::forget_window(WindowId w) {
    if (w == 0) return;
    model_.forget_window(w);
    mins_.erase(w);
}

void Engine::forget_space(SpaceId id) {
    for (WindowId w : model_.forget_space(id)) drop_if_untracked(w);
}

std::size_t Engine::tiled_count(SpaceId id) const {
    const Space *space = model_.find_space(id);
    return space ? space->tree.leaf_count() : 0;
}

std::string Engine::debug_dump(SpaceId id) const {
    const Space *space = model_.find_space(id);
    if (!space) return {};
    const LayoutResult l = layout(*space);
    char line[256];
    std::string out;
    std::snprintf(line, sizeof line, "space %" PRIu64 " display %" PRIu32 " usable %s leaves %zu\n", space->id,
                  space->display, to_string(space->usable).c_str(), space->tree.leaf_count());
    out += line;
    if (space->tree.empty()) out += "(empty)\n";
    std::function<void(const Node *, int)> walk = [&](const Node *n, int depth) {
        const std::string indent(static_cast<std::size_t>(depth) * 2, ' ');
        if (n->is_leaf()) {
            const Rect r = find_frame(l, n->window).value_or(Rect{});
            std::snprintf(line, sizeof line, "%swin 0x%" PRIx64 " %s\n", indent.c_str(), n->window,
                          to_string(r).c_str());
            out += line;
            return;
        }
        std::snprintf(line, sizeof line, "%s%s %.4f\n", indent.c_str(), to_string(n->orientation), n->ratio);
        out += line;
        walk(n->child[0].get(), depth + 1);
        walk(n->child[1].get(), depth + 1);
    };
    if (space->tree.root()) walk(space->tree.root(), 0);
    for (const auto &[w, g] : model_.ghosts_of(id)) {
        std::snprintf(line, sizeof line, "ghost 0x%" PRIx64 " sibling 0x%" PRIx64 " %s %s %.4f\n", w, g.sibling,
                      g.was_first ? "first" : "second", to_string(g.orientation), g.ratio);
        out += line;
    }
    return out;
}

} // namespace hypr
