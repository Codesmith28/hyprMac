#include "test_support.hpp"

#include "hypr/workspace_model.hpp"

using namespace hypr;

TEST_SUITE("workspace_model") {

TEST_CASE("index tracks tree membership") {
    WorkspaceModel m;
    Space &s = m.upsert_space(1, 5, {0, 0, 100, 100});
    REQUIRE(m.insert_root(s, 10));
    REQUIRE(m.split_leaf(s, 10, 11, Orientation::Vertical, 0.5, false));
    CHECK(s.last_inserted == 11);
    CHECK(m.tree_space_of(10) == 1);
    CHECK(m.space_of(11) == 1);
    CHECK_FALSE(m.insert_root(s, 12)); // tree not empty
    Space &t = m.upsert_space(2, 5, {0, 0, 100, 100});
    CHECK_FALSE(m.insert_root(t, 10)); // already tiled on space 1
    CHECK(m.check_invariants());
    CHECK(m.remove(10, false));
    CHECK_FALSE(m.remove(10, false));
    CHECK(m.space_of(10) == 0);
    CHECK(m.check_invariants());
}

TEST_CASE("ghost records sibling, side, orientation and ratio") {
    WorkspaceModel m;
    Space &s = m.upsert_space(1, 0, {});
    m.insert_root(s, 1);
    m.split_leaf(s, 1, 2, Orientation::Vertical, 0.3, false);
    m.split_leaf(s, 2, 3, Orientation::Horizontal, 0.5, false); // 1 | (2 / 3)

    REQUIRE(m.remove(1, true));
    const Ghost *g = m.ghost(1);
    REQUIRE(g != nullptr);
    CHECK(g->space == 1);
    CHECK(g->sibling == 2); // nearest leaf of (2 / 3)
    CHECK(g->was_first);
    CHECK(g->orientation == Orientation::Vertical);
    CHECK(g->ratio == doctest::Approx(0.3));
    CHECK(g->sibling_subtree == std::vector<WindowId>{2, 3});
    CHECK(m.space_of(1) == 1);
    CHECK(m.tree_space_of(1) == 0);

    REQUIRE(m.remove(3, true));
    CHECK(m.ghost(3)->sibling == 2);
    CHECK_FALSE(m.ghost(3)->was_first);
    CHECK(m.ghost(3)->seq > g->seq);

    REQUIRE(m.remove(2, true)); // the root: no sibling
    CHECK(m.ghost(2)->sibling == 0);
    CHECK(m.ghosts_of(1).size() == 3);
    CHECK(m.ghosts_of(1).front().first == 1);
    CHECK(m.check_invariants());
}

TEST_CASE("forget_space drops trees and ghosts of that space only") {
    WorkspaceModel m;
    Space &a = m.upsert_space(1, 0, {});
    Space &b = m.upsert_space(2, 0, {});
    m.insert_root(a, 1);
    m.split_leaf(a, 1, 2, Orientation::Vertical, 0.5, false);
    m.insert_root(b, 3);
    m.split_leaf(b, 3, 4, Orientation::Vertical, 0.5, false);
    m.remove(2, true);
    m.remove(4, true);
    auto dropped = m.forget_space(1);
    std::sort(dropped.begin(), dropped.end());
    CHECK(dropped == std::vector<WindowId>{1, 2});
    CHECK(m.find_space(1) == nullptr);
    CHECK(m.space_of(4) == 2);
    CHECK(m.ghost_count() == 1);
    CHECK(m.check_invariants());
}

TEST_CASE("swap requires both windows in the same tree") {
    WorkspaceModel m;
    Space &a = m.upsert_space(1, 0, {});
    Space &b = m.upsert_space(2, 0, {});
    m.insert_root(a, 1);
    m.split_leaf(a, 1, 2, Orientation::Vertical, 0.5, false);
    m.insert_root(b, 3);
    CHECK(m.swap(1, 2));
    CHECK(a.tree.windows() == std::vector<WindowId>{2, 1});
    CHECK_FALSE(m.swap(1, 3));
    CHECK_FALSE(m.swap(1, 99));
    m.forget_window(1);
    CHECK(m.space_of(1) == 0);
    CHECK(m.check_invariants());
}

} // TEST_SUITE
