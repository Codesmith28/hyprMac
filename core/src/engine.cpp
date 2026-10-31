#include "hypr/engine.hpp"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <functional>

namespace hypr {

namespace {

bool valid_min(double v) { return is_valid_scalar(v); }
double clean_min(double v) { return v > 0 ? v : 0.0; }

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

LayoutResult Engine::layout(const Space &space) const {
    return compute_layout(space.tree, space.usable, cfg_, [this](WindowId w) { return min_size(w); });
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
    const LayoutResult l = layout(space);
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
        if (w.min_w > 0 || w.min_h > 0) mins_[w.id].hint = {clean_min(w.min_w), clean_min(w.min_h)};
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
    for (auto it = inserts.rbegin(); it != inserts.rend(); ++it) dwindle_insert(space, *it, snap, pending);

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
    mins_[w].reported = {min_w, min_h};
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
