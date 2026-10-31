#pragma once
// Binary space partition tree. Leaves are windows; internal nodes are splits.
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace hypr {

using WindowId = std::uint64_t;

// Vertical   = children side by side (split along x; first child is left).
// Horizontal = children stacked     (split along y; first child is top).
enum class Orientation : std::uint8_t { Vertical, Horizontal };

const char *to_string(Orientation o);

struct Node {
    Node();
    ~Node();
    Node(const Node &) = delete;
    Node &operator=(const Node &) = delete;

    Node *parent = nullptr;
    std::unique_ptr<Node> child[2]; // both null for a leaf, both set for a split
    WindowId window = 0;            // leaves only
    Orientation orientation = Orientation::Vertical; // splits only
    double ratio = 0.5;             // splits only: share of the FIRST child, in [0.1, 0.9]

    bool is_leaf() const { return !child[0]; }
};

class LayoutTree {
public:
    LayoutTree() = default;
    LayoutTree(LayoutTree &&) noexcept = default;
    LayoutTree &operator=(LayoutTree &&) noexcept = default;
    LayoutTree(const LayoutTree &) = delete;
    LayoutTree &operator=(const LayoutTree &) = delete;

    bool empty() const { return !root_; }
    std::size_t leaf_count() const { return index_.size(); }
    const Node *root() const { return root_.get(); }

    const Node *find(WindowId w) const;
    bool contains(WindowId w) const { return index_.count(w) != 0; }

    // Make w the single leaf of an empty tree. False if non-empty, w == 0 or w present.
    bool insert_root(WindowId w);

    // Dwindle-style insert: split the leaf of `target`; the existing window becomes
    // the first child and `w` the second. Equivalent to split_leaf(..., false).
    bool insert(WindowId target, WindowId w, Orientation o, double ratio);

    // Split the leaf of `target`, placing `w` first (new_is_first) or second.
    bool split_leaf(WindowId target, WindowId w, Orientation o, double ratio, bool new_is_first);

    // Replace the subtree rooted at `target` (a node of THIS tree) with a new split
    // whose children are that subtree and a new leaf `w`. Ratio is clamped to
    // [0.1, 0.9]; non-finite ratios, w == 0 and duplicate w are rejected.
    bool wrap(const Node *target, WindowId w, Orientation o, double ratio, bool new_is_first);

    // Set the ratio of a split node of THIS tree (clamped to [0.1, 0.9]). False for leaves,
    // foreign nodes or non-finite ratios.
    bool set_ratio(const Node *split, double ratio);

    // Remove w's leaf; its sibling subtree takes the parent's place. False if absent.
    bool remove(WindowId w);

    // Exchange the positions of two windows. False if either is absent.
    bool swap(WindowId a, WindowId b);

    // Windows in tree order (first child before second child).
    std::vector<WindowId> windows() const;

    static void collect(const Node *n, std::vector<WindowId> &out);
    static WindowId first_leaf(const Node *n); // left/top-most leaf of a subtree
    static WindowId last_leaf(const Node *n);  // right/bottom-most leaf of a subtree

    // Parent links consistent, every split has exactly two children, ratios in
    // [0.1, 0.9], window ids non-zero and unique, index in sync with the leaves.
    bool check_invariants(std::string *why = nullptr) const;

    // Number of Node objects currently alive in the process (leak checks in tests).
    static long live_node_count();

private:
    std::unique_ptr<Node> &slot_of(Node *n);
    bool owns(const Node *n) const;

    std::unique_ptr<Node> root_;
    std::unordered_map<WindowId, Node *> index_;
};

} // namespace hypr
