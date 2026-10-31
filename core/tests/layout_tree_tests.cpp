#include "test_support.hpp"

#include "hypr/layout_tree.hpp"

#include <vector>

using hypr::LayoutTree;
using hypr::Node;
using hypr::Orientation;
using hypr::WindowId;
using V = std::vector<WindowId>;

namespace {

void require_ok(const LayoutTree &t) {
    std::string why;
    REQUIRE_MESSAGE(t.check_invariants(&why), why);
}

// A | (B / (C | D))
LayoutTree four() {
    LayoutTree t;
    REQUIRE(t.insert_root(1));
    REQUIRE(t.insert(1, 2, Orientation::Vertical, 0.5));
    REQUIRE(t.insert(2, 3, Orientation::Horizontal, 0.5));
    REQUIRE(t.insert(3, 4, Orientation::Vertical, 0.5));
    require_ok(t);
    return t;
}

} // namespace

TEST_SUITE("layout_tree") {

TEST_CASE("empty tree") {
    LayoutTree t;
    CHECK(t.empty());
    CHECK(t.leaf_count() == 0);
    CHECK(t.root() == nullptr);
    CHECK(t.find(1) == nullptr);
    CHECK(t.windows().empty());
    CHECK_FALSE(t.remove(1));
    CHECK_FALSE(t.insert(1, 2, Orientation::Vertical, 0.5));
    require_ok(t);
}

TEST_CASE("insert_root rejects id 0, duplicates and non-empty trees") {
    LayoutTree t;
    CHECK_FALSE(t.insert_root(0));
    CHECK(t.insert_root(7));
    CHECK_FALSE(t.insert_root(8));
    CHECK(t.leaf_count() == 1);
    CHECK(t.root()->is_leaf());
    CHECK(t.root()->window == 7);
    require_ok(t);
}

TEST_CASE("insert puts the existing window first and the new window second") {
    LayoutTree t;
    t.insert_root(1);
    REQUIRE(t.insert(1, 2, Orientation::Horizontal, 0.3));
    const Node *r = t.root();
    CHECK_FALSE(r->is_leaf());
    CHECK(r->orientation == Orientation::Horizontal);
    CHECK(r->ratio == 0.3);
    CHECK(r->child[0]->window == 1);
    CHECK(r->child[1]->window == 2);
    CHECK(t.find(2)->parent == r);
    CHECK_FALSE(t.insert(1, 2, Orientation::Vertical, 0.5)); // duplicate
    CHECK_FALSE(t.insert(1, 0, Orientation::Vertical, 0.5)); // id 0
    CHECK_FALSE(t.insert(9, 3, Orientation::Vertical, 0.5)); // unknown target
    require_ok(t);
}

TEST_CASE("split_leaf can place the new window first") {
    LayoutTree t;
    t.insert_root(1);
    REQUIRE(t.split_leaf(1, 2, Orientation::Vertical, 0.5, true));
    CHECK(t.windows() == V{2, 1});
    require_ok(t);
}

TEST_CASE("wrap an internal subtree") {
    LayoutTree t = four();
    const Node *sub = t.find(2)->parent; // (B / (C | D))
    REQUIRE(t.wrap(sub, 5, Orientation::Horizontal, 0.4, true));
    CHECK(t.windows() == V{1, 5, 2, 3, 4});
    const Node *w = t.find(5)->parent;
    CHECK(w->child[1].get() == sub);
    CHECK(sub->parent == w);
    CHECK(w->parent == t.root());
    require_ok(t);
}

TEST_CASE("wrap clamps ratios and rejects bad input") {
    LayoutTree t;
    t.insert_root(1);
    REQUIRE(t.split_leaf(1, 2, Orientation::Vertical, 0.95, false));
    CHECK(t.root()->ratio == doctest::Approx(0.9));
    REQUIRE(t.split_leaf(1, 3, Orientation::Vertical, 0.01, false));
    CHECK(t.find(3)->parent->ratio == doctest::Approx(0.1));
    CHECK_FALSE(t.split_leaf(1, 4, Orientation::Vertical, std::numeric_limits<double>::quiet_NaN(), false));

    LayoutTree other;
    other.insert_root(9);
    CHECK_FALSE(t.wrap(other.root(), 5, Orientation::Vertical, 0.5, false)); // foreign node
    CHECK_FALSE(t.wrap(nullptr, 5, Orientation::Vertical, 0.5, false));
    require_ok(t);
    require_ok(other);
}

TEST_CASE("remove a first-child leaf promotes its sibling subtree") {
    LayoutTree t = four();
    REQUIRE(t.remove(1)); // root's first child -> (B / (C | D)) becomes root
    CHECK(t.windows() == V{2, 3, 4});
    CHECK(t.root()->parent == nullptr);
    CHECK(t.root()->orientation == Orientation::Horizontal);
    require_ok(t);
}

TEST_CASE("remove a second-child leaf") {
    LayoutTree t = four();
    REQUIRE(t.remove(4)); // C takes the place of (C | D)
    CHECK(t.windows() == V{1, 2, 3});
    CHECK(t.find(3)->parent == t.find(2)->parent);
    require_ok(t);
}

TEST_CASE("remove a middle leaf keeps parent links") {
    LayoutTree t = four();
    REQUIRE(t.remove(2)); // (C | D) takes B's parent's place
    CHECK(t.windows() == V{1, 3, 4});
    const Node *cd = t.find(3)->parent;
    CHECK(cd->parent == t.root());
    CHECK(cd->orientation == Orientation::Vertical);
    require_ok(t);
}

TEST_CASE("remove the last window and the root") {
    LayoutTree t;
    t.insert_root(1);
    REQUIRE(t.remove(1));
    CHECK(t.empty());
    require_ok(t);

    t.insert_root(1);
    t.insert(1, 2, Orientation::Vertical, 0.5);
    REQUIRE(t.remove(2));
    CHECK(t.root()->is_leaf());
    CHECK(t.root()->window == 1);
    CHECK(t.root()->parent == nullptr);
    require_ok(t);
    CHECK_FALSE(t.remove(2));
}

TEST_CASE("swap exchanges positions") {
    LayoutTree t = four();
    const Node *n1 = t.find(1);
    const Node *n4 = t.find(4);
    REQUIRE(t.swap(1, 4));
    CHECK(t.windows() == V{4, 2, 3, 1});
    CHECK(t.find(1) == n4);
    CHECK(t.find(4) == n1);
    CHECK(t.swap(2, 2));
    CHECK_FALSE(t.swap(2, 99));
    require_ok(t);
}

TEST_CASE("first_leaf and last_leaf") {
    LayoutTree t = four();
    const Node *sub = t.find(2)->parent;
    CHECK(LayoutTree::first_leaf(t.root()) == 1);
    CHECK(LayoutTree::last_leaf(t.root()) == 4);
    CHECK(LayoutTree::first_leaf(sub) == 2);
    CHECK(LayoutTree::last_leaf(sub) == 4);
    CHECK(LayoutTree::first_leaf(nullptr) == 0);
}

TEST_CASE("check_invariants detects a bad ratio") {
    LayoutTree t = four();
    const_cast<Node *>(t.root())->ratio = 0.95;
    std::string why;
    CHECK_FALSE(t.check_invariants(&why));
    CHECK(why == "ratio out of range");
    const_cast<Node *>(t.root())->ratio = 0.5;
    CHECK(t.check_invariants());
}

TEST_CASE("nodes are released (no leaks)") {
    const long before = LayoutTree::live_node_count();
    {
        LayoutTree t = four();
        CHECK(LayoutTree::live_node_count() == before + 7);
        t.remove(3);
        CHECK(LayoutTree::live_node_count() == before + 5);
        LayoutTree moved = std::move(t);
        CHECK(moved.leaf_count() == 3);
    }
    CHECK(LayoutTree::live_node_count() == before);
}

} // TEST_SUITE
