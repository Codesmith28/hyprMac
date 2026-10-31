#include "hypr/workspace_model.hpp"

#include <algorithm>

namespace hypr {

Space *WorkspaceModel::find_space(SpaceId id) {
    auto it = spaces_.find(id);
    return it == spaces_.end() ? nullptr : &it->second;
}

const Space *WorkspaceModel::find_space(SpaceId id) const {
    auto it = spaces_.find(id);
    return it == spaces_.end() ? nullptr : &it->second;
}

Space &WorkspaceModel::upsert_space(SpaceId id, DisplayId display, const Rect &usable) {
    Space &s = spaces_[id];
    s.id = id;
    s.display = display;
    s.usable = usable;
    return s;
}

std::vector<WindowId> WorkspaceModel::forget_space(SpaceId id) {
    std::vector<WindowId> dropped;
    auto it = spaces_.find(id);
    if (it != spaces_.end()) {
        dropped = it->second.tree.windows();
        for (WindowId w : dropped) tree_index_.erase(w);
        spaces_.erase(it);
    }
    for (auto g = ghosts_.begin(); g != ghosts_.end();) {
        if (g->second.space == id) {
            dropped.push_back(g->first);
            g = ghosts_.erase(g);
        } else {
            ++g;
        }
    }
    return dropped;
}

SpaceId WorkspaceModel::tree_space_of(WindowId w) const {
    auto it = tree_index_.find(w);
    return it == tree_index_.end() ? 0 : it->second;
}

SpaceId WorkspaceModel::space_of(WindowId w) const {
    if (SpaceId s = tree_space_of(w)) return s;
    auto g = ghosts_.find(w);
    return g == ghosts_.end() ? 0 : g->second.space;
}

const Ghost *WorkspaceModel::ghost(WindowId w) const {
    auto g = ghosts_.find(w);
    return g == ghosts_.end() ? nullptr : &g->second;
}

void WorkspaceModel::drop_ghost(WindowId w) { ghosts_.erase(w); }

bool WorkspaceModel::insert_root(Space &space, WindowId w) {
    if (tree_index_.count(w)) return false;
    tree_index_.emplace(w, space.id);
    if (!space.tree.insert_root(w)) {
        tree_index_.erase(w);
        return false;
    }
    space.last_inserted = w;
    return true;
}

bool WorkspaceModel::split_leaf(Space &space, WindowId target, WindowId w, Orientation o, double ratio,
                                bool new_is_first) {
    const Node *t = space.tree.find(target);
    return t && wrap(space, t, w, o, ratio, new_is_first);
}

bool WorkspaceModel::wrap(Space &space, const Node *target, WindowId w, Orientation o, double ratio,
                          bool new_is_first) {
    if (tree_index_.count(w)) return false;
    tree_index_.emplace(w, space.id);
    if (!space.tree.wrap(target, w, o, ratio, new_is_first)) {
        tree_index_.erase(w);
        return false;
    }
    space.last_inserted = w;
    return true;
}

bool WorkspaceModel::remove(WindowId w, bool make_ghost) {
    const SpaceId sid = tree_space_of(w);
    Space *space = find_space(sid);
    if (!space) return false;
    const Node *leaf = space->tree.find(w);
    if (!leaf) return false;

    if (make_ghost) {
        Ghost g;
        g.space = sid;
        g.seq = ++ghost_seq_;
        if (const Node *parent = leaf->parent) {
            g.was_first = parent->child[0].get() == leaf;
            const Node *sib = parent->child[g.was_first ? 1 : 0].get();
            // Nearest leaf of the sibling subtree: the one adjacent to the window.
            g.sibling = g.was_first ? LayoutTree::first_leaf(sib) : LayoutTree::last_leaf(sib);
            g.orientation = parent->orientation;
            g.ratio = parent->ratio;
            LayoutTree::collect(sib, g.sibling_subtree);
        }
        ghosts_[w] = std::move(g);
    }
    space->tree.remove(w);
    tree_index_.erase(w);
    return true;
}

bool WorkspaceModel::swap(WindowId a, WindowId b) {
    const SpaceId sa = tree_space_of(a);
    if (sa == 0 || sa != tree_space_of(b)) return false;
    return find_space(sa)->tree.swap(a, b);
}

void WorkspaceModel::forget_window(WindowId w) {
    remove(w, false);
    ghosts_.erase(w);
}

std::vector<std::pair<WindowId, Ghost>> WorkspaceModel::ghosts_of(SpaceId id) const {
    std::vector<std::pair<WindowId, Ghost>> out;
    for (const auto &[w, g] : ghosts_)
        if (g.space == id) out.emplace_back(w, g);
    std::sort(out.begin(), out.end(), [](const auto &x, const auto &y) { return x.second.seq < y.second.seq; });
    return out;
}

bool WorkspaceModel::check_invariants(std::string *why) const {
    auto fail = [&](const std::string &msg) {
        if (why) *why = msg;
        return false;
    };
    std::size_t leaves = 0;
    for (const auto &[id, space] : spaces_) {
        if (space.id != id) return fail("space id mismatch");
        std::string err;
        if (!space.tree.check_invariants(&err)) return fail("space " + std::to_string(id) + ": " + err);
        for (WindowId w : space.tree.windows()) {
            if (tree_space_of(w) != id) return fail("tree index out of sync for window " + std::to_string(w));
            if (ghosts_.count(w)) return fail("window both tiled and ghosted: " + std::to_string(w));
        }
        leaves += space.tree.leaf_count();
    }
    if (leaves != tree_index_.size()) return fail("tree index has stale entries");
    for (const auto &[w, g] : ghosts_) {
        if (w == 0) return fail("ghost with window id 0");
        if (g.space == 0) return fail("ghost without a space");
    }
    return true;
}

} // namespace hypr
