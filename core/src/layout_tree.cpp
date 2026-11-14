#include "hypr/layout_tree.hpp"

#include "hypr/config.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <functional>
#include <unordered_set>

namespace hypr {

namespace {
std::atomic<long> g_live_nodes{0};
} // namespace

Node::Node() { g_live_nodes.fetch_add(1, std::memory_order_relaxed); }
Node::~Node() { g_live_nodes.fetch_sub(1, std::memory_order_relaxed); }

long LayoutTree::live_node_count() { return g_live_nodes.load(std::memory_order_relaxed); }

const char *to_string(Orientation o) { return o == Orientation::Vertical ? "V" : "H"; }

const Node *LayoutTree::find(WindowId w) const {
    auto it = index_.find(w);
    return it == index_.end() ? nullptr : it->second;
}

bool LayoutTree::insert_root(WindowId w) {
    if (root_ || w == 0) return false;
    auto leaf = std::make_unique<Node>();
    leaf->window = w;
    index_.emplace(w, leaf.get());
    root_ = std::move(leaf);
    return true;
}

bool LayoutTree::insert(WindowId target, WindowId w, Orientation o, double ratio) {
    return split_leaf(target, w, o, ratio, false);
}

bool LayoutTree::split_leaf(WindowId target, WindowId w, Orientation o, double ratio, bool new_is_first) {
    const Node *t = find(target);
    if (!t) return false;
    return wrap(t, w, o, ratio, new_is_first);
}

std::unique_ptr<Node> &LayoutTree::slot_of(Node *n) {
    if (!n->parent) return root_;
    return n->parent->child[0].get() == n ? n->parent->child[0] : n->parent->child[1];
}

bool LayoutTree::owns(const Node *n) const {
    if (!n) return false;
    while (n->parent) n = n->parent;
    return n == root_.get();
}

bool LayoutTree::wrap(const Node *target_c, WindowId w, Orientation o, double ratio, bool new_is_first) {
    if (w == 0 || contains(w) || !std::isfinite(ratio) || !owns(target_c)) return false;
    ratio = std::clamp(ratio, kMinRatio, kMaxRatio);

    // Allocate everything before touching the tree so a throw leaves it intact.
    auto leaf = std::make_unique<Node>();
    auto split = std::make_unique<Node>();
    leaf->window = w;
    split->orientation = o;
    split->ratio = ratio;
    Node *leaf_raw = leaf.get();
    index_.emplace(w, leaf_raw);

    Node *target = const_cast<Node *>(target_c); // we own it (checked above)
    std::unique_ptr<Node> &slot = slot_of(target);
    std::unique_ptr<Node> old = std::move(slot);
    split->parent = old->parent;
    old->parent = split.get();
    leaf->parent = split.get();
    split->child[new_is_first ? 0 : 1] = std::move(leaf);
    split->child[new_is_first ? 1 : 0] = std::move(old);
    slot = std::move(split);
    return true;
}

bool LayoutTree::set_ratio(const Node *split, double ratio) {
    if (!split || split->is_leaf() || !std::isfinite(ratio) || !owns(split)) return false;
    const_cast<Node *>(split)->ratio = std::clamp(ratio, kMinRatio, kMaxRatio); // we own it (checked above)
    return true;
}

bool LayoutTree::set_orientation(const Node *split, Orientation o) {
    if (!split || split->is_leaf() || !owns(split)) return false;
    const_cast<Node *>(split)->orientation = o; // we own it (checked above)
    return true;
}

bool LayoutTree::remove(WindowId w) {
    auto it = index_.find(w);
    if (it == index_.end()) return false;
    Node *leaf = it->second;
    index_.erase(it);
    Node *parent = leaf->parent;
    if (!parent) {
        root_.reset();
        return true;
    }
    const int idx = parent->child[0].get() == leaf ? 0 : 1;
    std::unique_ptr<Node> sibling = std::move(parent->child[1 - idx]);
    sibling->parent = parent->parent;
    slot_of(parent) = std::move(sibling); // destroys parent and the removed leaf
    return true;
}

bool LayoutTree::swap(WindowId a, WindowId b) {
    auto ia = index_.find(a);
    auto ib = index_.find(b);
    if (ia == index_.end() || ib == index_.end()) return false;
    if (a == b) return true;
    Node *na = ia->second;
    Node *nb = ib->second;
    std::swap(na->window, nb->window);
    ia->second = nb;
    ib->second = na;
    return true;
}

void LayoutTree::collect(const Node *n, std::vector<WindowId> &out) {
    if (!n) return;
    if (n->is_leaf()) {
        out.push_back(n->window);
        return;
    }
    collect(n->child[0].get(), out);
    collect(n->child[1].get(), out);
}

std::vector<WindowId> LayoutTree::windows() const {
    std::vector<WindowId> out;
    out.reserve(index_.size());
    collect(root_.get(), out);
    return out;
}

WindowId LayoutTree::first_leaf(const Node *n) {
    if (!n) return 0;
    while (!n->is_leaf()) n = n->child[0].get();
    return n->window;
}

WindowId LayoutTree::last_leaf(const Node *n) {
    if (!n) return 0;
    while (!n->is_leaf()) n = n->child[1].get();
    return n->window;
}

bool LayoutTree::check_invariants(std::string *why) const {
    auto fail = [&](const std::string &msg) {
        if (why) *why = msg;
        return false;
    };
    if (!root_) return index_.empty() ? true : fail("empty tree with non-empty index");
    if (root_->parent) return fail("root has a parent");

    std::unordered_set<WindowId> seen;
    std::string err;
    auto bad = [&err](const char *msg) {
        err = msg;
        return false;
    };
    std::function<bool(const Node *)> walk = [&](const Node *n) -> bool {
        const bool has0 = static_cast<bool>(n->child[0]);
        const bool has1 = static_cast<bool>(n->child[1]);
        if (has0 != has1) return bad("split with one child");
        if (!has0) {
            if (n->window == 0) return bad("leaf with window id 0");
            if (!seen.insert(n->window).second) return bad("duplicate window id");
            auto it = index_.find(n->window);
            if (it == index_.end() || it->second != n) return bad("index out of sync");
            return true;
        }
        if (!std::isfinite(n->ratio) || n->ratio < kMinRatio || n->ratio > kMaxRatio)
            return bad("ratio out of range");
        for (const auto &c : n->child) {
            if (c->parent != n) return bad("inconsistent parent link");
            if (!walk(c.get())) return false;
        }
        return true;
    };
    if (!walk(root_.get())) return fail(err);
    if (seen.size() != index_.size()) return fail("index has stale entries");
    return true;
}

} // namespace hypr
