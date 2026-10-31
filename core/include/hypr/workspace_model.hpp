#pragma once
// Membership state: one LayoutTree per space, a window -> space index and ghost
// slots for windows that are temporarily gone (minimized, fullscreen, hidden).
// Policy (what to insert where) lives in Engine; this class keeps the indexes
// consistent with the trees.
#include "hypr/geometry.hpp"
#include "hypr/layout_tree.hpp"

#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

namespace hypr {

using SpaceId = std::uint64_t;
using DisplayId = std::uint32_t;

struct Space {
    SpaceId id = 0;
    DisplayId display = 0;
    Rect usable;
    LayoutTree tree;
    WindowId last_inserted = 0; // most recently inserted window (may have left since)
};

// Where a window sat when it was removed into a ghost slot.
struct Ghost {
    SpaceId space = 0;
    WindowId sibling = 0;       // nearest leaf of the sibling subtree; 0 if it was the root
    bool was_first = false;     // the window was the first (left/top) child
    Orientation orientation = Orientation::Vertical;
    double ratio = 0.5;
    std::uint64_t seq = 0;      // creation order (restores run newest first)
    std::vector<WindowId> sibling_subtree; // every window of the sibling subtree
};

class WorkspaceModel {
public:
    Space *find_space(SpaceId id);
    const Space *find_space(SpaceId id) const;

    // Create the space if needed and record its display and usable rect.
    Space &upsert_space(SpaceId id, DisplayId display, const Rect &usable);

    // Drop a space's tree, its index entries and the ghosts recorded against it.
    // Returns every window that was dropped (tree leaves and ghosts).
    std::vector<WindowId> forget_space(SpaceId id);

    // Space whose TREE holds w; 0 if none.
    SpaceId tree_space_of(WindowId w) const;
    // Space whose tree or ghost slot holds w; 0 if none.
    SpaceId space_of(WindowId w) const;

    const Ghost *ghost(WindowId w) const;
    void drop_ghost(WindowId w);

    // Tree edits that keep the index in sync. Each sets space.last_inserted = w.
    bool insert_root(Space &space, WindowId w);
    bool split_leaf(Space &space, WindowId target, WindowId w, Orientation o, double ratio, bool new_is_first);
    bool wrap(Space &space, const Node *target, WindowId w, Orientation o, double ratio, bool new_is_first);

    // Remove w from whichever tree holds it. With make_ghost, a ghost slot is
    // recorded against that space. False when w is in no tree.
    bool remove(WindowId w, bool make_ghost);

    // Swap two windows; both must be in the same tree.
    bool swap(WindowId a, WindowId b);

    // Remove w from any tree (no ghost) and drop its ghost slot.
    void forget_window(WindowId w);

    const std::map<SpaceId, Space> &spaces() const { return spaces_; }
    std::size_t ghost_count() const { return ghosts_.size(); }
    std::vector<std::pair<WindowId, Ghost>> ghosts_of(SpaceId id) const; // sorted by seq

    // Trees valid, index matches the trees exactly, ghosts disjoint from trees.
    bool check_invariants(std::string *why = nullptr) const;

private:
    std::map<SpaceId, Space> spaces_; // ordered: deterministic iteration
    std::unordered_map<WindowId, SpaceId> tree_index_;
    std::unordered_map<WindowId, Ghost> ghosts_;
    std::uint64_t ghost_seq_ = 0;
};

} // namespace hypr
