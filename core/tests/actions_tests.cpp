// Keyboard actions: resize_step, equalize, rotate_split, move_beside, toggle_zoom, move_to_space.
#include "engine_support.hpp"

#include "hypr/hypr_core.h"

#include <cmath>
#include <memory>

using namespace hypr;
using namespace hypr::test;

namespace {

constexpr SpaceId S = 7;
constexpr SpaceId S2 = 8;

// Windows 1..n opened one reconcile at a time (dwindle): 1 | (2 / (3 | ...)).
Plan open(Engine &e, int n, SpaceId space = S, DisplayId display = 1, WindowId first = 1) {
    Plan p;
    for (int k = 1; k <= n; ++k) {
        Snapshot s = snap(space, {}, 0, kUsable, display);
        for (int w = k; w >= 1; --w) s.windows.push_back({first + static_cast<WindowId>(w) - 1, St::Tiled, {}, 0, 0});
        p = reconcile_ok(e, s);
    }
    return p;
}

void ratios(const Node *n, std::vector<double> &out) {
    if (!n || n->is_leaf()) return;
    out.push_back(n->ratio);
    ratios(n->child[0].get(), out);
    ratios(n->child[1].get(), out);
}

std::vector<double> ratios_of(const Engine &e, SpaceId s) {
    std::vector<double> r;
    ratios(e.model().find_space(s)->tree.root(), r);
    return r;
}

Plan step(Engine &e, WindowId w, Direction d) {
    Plan p;
    REQUIRE(e.resize_step(w, d, p) == HM_OK);
    return p;
}

} // namespace

TEST_SUITE("engine: keyboard resize") {

TEST_CASE("resize_right on the left window moves the boundary right by 5% of the split") {
    Engine e;
    const Plan before = open(e, 2);
    CHECK_RECT(frame(before, 1), 12, 12, 704, 876);
    const Plan p = step(e, 1, Direction::Right);
    CHECK(p.revision > before.revision);
    CHECK(p.space == S);
    CHECK(e.model().find_space(S)->tree.root()->ratio == doctest::Approx(0.55));
    CHECK_RECT(frame(p, 1), 12, 12, 774.4, 876);
    CHECK_RECT(frame(p, 2), 794.4, 12, 633.6, 876);
    CHECK(e.model().check_invariants());
}

TEST_CASE("resize_left on the left window has no split on its left: its right edge moves left") {
    Engine e;
    open(e, 2);
    const Plan p = step(e, 1, Direction::Left);
    CHECK_RECT(frame(p, 1), 12, 12, 633.6, 876);
    CHECK_RECT(frame(p, 2), 653.6, 12, 774.4, 876);
}

TEST_CASE("the key always moves the boundary the way it points, whichever side the window is on") {
    Engine e;
    open(e, 2);
    Plan p = step(e, 2, Direction::Left); // window 2's own left edge
    CHECK(e.model().find_space(S)->tree.root()->ratio == doctest::Approx(0.45));
    p = step(e, 2, Direction::Right); // no split on its right: the same boundary moves right
    CHECK(e.model().find_space(S)->tree.root()->ratio == doctest::Approx(0.5));
    p = step(e, 2, Direction::Right);
    CHECK(e.model().find_space(S)->tree.root()->ratio == doctest::Approx(0.55));
    CHECK_RECT(frame(p, 2), 794.4, 12, 633.6, 876);
}

TEST_CASE("vertical keys use the nearest horizontal split, even when the window sits in a deeper tree") {
    Engine e;
    open(e, 3); // 1 | (2 / 3)
    const Rect f1 = frame(e.layout_of(S), 1);
    Plan p = step(e, 2, Direction::Down);
    const auto r = ratios_of(e, S); // tree order: root (vertical), inner (horizontal)
    CHECK(r[0] == doctest::Approx(0.5));
    CHECK(r[1] == doctest::Approx(0.55));
    CHECK_RECT(frame(p, 1), f1.x, f1.y, f1.w, f1.h);
    p = step(e, 3, Direction::Up); // window 3's top edge is that same boundary
    CHECK(ratios_of(e, S)[1] == doctest::Approx(0.5));
    p = step(e, 3, Direction::Down); // no split below window 3: the boundary moves down
    CHECK(ratios_of(e, S)[1] == doctest::Approx(0.55));
}

TEST_CASE("a window with no split on that axis leaves the layout alone") {
    Engine e;
    open(e, 2); // only a vertical split
    const LayoutResult l = e.layout_of(S);
    const Plan p = step(e, 1, Direction::Up);
    REQUIRE(p.placements.size() == l.placements.size());
    for (std::size_t i = 0; i < l.placements.size(); ++i) CHECK(p.placements[i].frame == l.placements[i].frame);
    CHECK(step(e, 2, Direction::Down).placements.size() == 2);
    CHECK(ratios_of(e, S)[0] == doctest::Approx(0.5));
}

TEST_CASE("a single window is a successful no-op") {
    Engine e;
    open(e, 1);
    const Plan p = step(e, 1, Direction::Right);
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
}

TEST_CASE("resize_step is the configured percentage of the split") {
    Config c;
    c.resize_step = 25;
    Engine e(c);
    open(e, 2);
    step(e, 1, Direction::Right);
    CHECK(ratios_of(e, S)[0] == doctest::Approx(0.75));
    c.resize_step = 1;
    REQUIRE(e.set_config(c) == HM_OK);
    step(e, 1, Direction::Left);
    CHECK(ratios_of(e, S)[0] == doctest::Approx(0.74));
}

TEST_CASE("ratios stay within [0.1, 0.9]") {
    Engine e;
    open(e, 2);
    for (int i = 0; i < 40; ++i) step(e, 1, Direction::Right);
    CHECK(ratios_of(e, S)[0] == doctest::Approx(0.9));
    CHECK_RECT(frame(step(e, 1, Direction::Right), 1), 12, 12, 1267.2, 876);
    for (int i = 0; i < 40; ++i) step(e, 1, Direction::Left);
    CHECK(ratios_of(e, S)[0] == doctest::Approx(0.1));
}

TEST_CASE("window minimum sizes cap the step") {
    Engine e;
    open(e, 2);
    REQUIRE(e.report_min_size(2, 700, 0) == HM_OK);
    for (int i = 0; i < 10; ++i) step(e, 1, Direction::Right);
    const Plan p = step(e, 1, Direction::Right);
    CHECK(frame(p, 2).w >= 700 - 1e-6);
    CHECK(frame(p, 1).w + frame(p, 2).w + 8 == doctest::Approx(1416));
}

TEST_CASE("an unsatisfiable minimum never makes a key move the boundary against it") {
    Engine e;
    open(e, 2);
    REQUIRE(e.report_min_size(2, 1000, 0) == HM_OK); // window 2 wants 1000 of 1408: the boundary is drawn at 408
    const double shown = frame(e.layout_of(S), 1).w;
    CHECK(shown == doctest::Approx(408));
    CHECK(frame(step(e, 1, Direction::Right), 1).w >= shown - 1e-9); // growing window 1 must not shrink it
    CHECK(frame(step(e, 1, Direction::Left), 1).w <= shown + 1e-9);
    CHECK(frame(e.layout_of(S), 2).w >= 1000 - 1e-9);
}

TEST_CASE("a step starts from the boundary as drawn, not from a ratio the minimums overrode") {
    Engine e;
    open(e, 2);
    REQUIRE(e.report_min_size(1, 900, 0) == HM_OK); // stored 0.5 (704 wide) is drawn at 900
    CHECK(frame(e.layout_of(S), 1).w == doctest::Approx(900));
    const Plan p = step(e, 1, Direction::Right);
    CHECK(frame(p, 1).w == doctest::Approx(900 + 70.4));
    const Plan q = step(e, 1, Direction::Left);
    CHECK(frame(q, 1).w == doctest::Approx(900));
}

TEST_CASE("resize_step errors") {
    Engine e;
    open(e, 2);
    Plan p;
    CHECK(e.resize_step(0, Direction::Left, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.resize_step(99, Direction::Left, p) == HM_ERR_UNKNOWN_WINDOW);
    // A floating window is not a tiled leaf.
    reconcile_ok(e, snap(S, {{1}, {2, St::Floating}}));
    CHECK(e.resize_step(2, Direction::Left, p) == HM_ERR_UNKNOWN_WINDOW);
}

} // TEST_SUITE

TEST_SUITE("engine: equalize") {

TEST_CASE("equalize resets every ratio in the space to split_ratio") {
    Engine e;
    open(e, 4);
    for (WindowId w : {1, 2, 3, 4}) step(e, w, Direction::Right);
    Plan p;
    REQUIRE(e.equalize(S, p) == HM_OK);
    for (double r : ratios_of(e, S)) CHECK(r == 0.5);
    const Plan fresh = [&] {
        Engine f;
        return open(f, 4);
    }();
    for (WindowId w : {1, 2, 3, 4}) CHECK(frame(p, w) == frame(fresh, w));
    CHECK(e.model().check_invariants());
}

TEST_CASE("equalize honours a configured split_ratio") {
    Config c;
    c.split_ratio = 0.6;
    Engine e(c);
    open(e, 3);
    step(e, 1, Direction::Left);
    Plan p;
    REQUIRE(e.equalize(S, p) == HM_OK);
    for (double r : ratios_of(e, S)) CHECK(r == doctest::Approx(0.6));
}

TEST_CASE("equalize only touches its own space and rejects unknown spaces") {
    Engine e;
    open(e, 2, S);
    open(e, 2, S2, 2, 10);
    step(e, 10, Direction::Right);
    Plan p;
    REQUIRE(e.equalize(S, p) == HM_OK);
    CHECK(p.space == S);
    CHECK(ratios_of(e, S2)[0] == doctest::Approx(0.55));
    CHECK(e.equalize(999, p) == HM_ERR_UNKNOWN_SPACE);
}

TEST_CASE("equalize on an empty space or one window is fine") {
    Engine e;
    reconcile_ok(e, snap(S, {{1, St::Floating}}));
    Plan p;
    CHECK(e.equalize(S, p) == HM_OK);
    CHECK(p.placements.empty());
}

} // TEST_SUITE

TEST_SUITE("engine: move_beside") {

TEST_CASE("side by side becomes stacked: dropping 1 on the bottom of 2 puts 2 on top") {
    Engine e;
    open(e, 2);
    Plan p;
    REQUIRE(e.move_beside(1, 2, Direction::Down, p) == HM_OK);
    CHECK_RECT(frame(p, 2), 12, 12, 1416, 434);
    CHECK_RECT(frame(p, 1), 12, 454, 1416, 434);
    CHECK(e.model().find_space(S)->tree.root()->orientation == Orientation::Horizontal);
    CHECK(e.model().check_invariants());
}

TEST_CASE("the side picks both the orientation and which child is first") {
    const struct { Direction side; Orientation o; bool first; } cases[] = {
        {Direction::Left, Orientation::Vertical, true},  {Direction::Right, Orientation::Vertical, false},
        {Direction::Up, Orientation::Horizontal, true},  {Direction::Down, Orientation::Horizontal, false},
    };
    for (const auto &c : cases) {
        Engine e;
        open(e, 2);
        Plan p;
        REQUIRE(e.move_beside(1, 2, c.side, p) == HM_OK);
        const Node *root = e.model().find_space(S)->tree.root();
        CHECK(root->orientation == c.o);
        CHECK(root->ratio == doctest::Approx(0.5));
        CHECK((root->child[c.first ? 0 : 1]->window == 1));
    }
}

TEST_CASE("in a bigger tree only the dragged window moves; the rest keeps its shape") {
    Engine e;
    open(e, 3); // 1 | (2 / 3)
    Plan p;
    REQUIRE(e.move_beside(1, 3, Direction::Right, p) == HM_OK); // 2 / (3 | 1)
    const Node *root = e.model().find_space(S)->tree.root();
    CHECK(root->orientation == Orientation::Horizontal);
    CHECK(root->child[0]->window == 2);
    CHECK(root->child[1]->orientation == Orientation::Vertical);
    CHECK(root->child[1]->child[0]->window == 3);
    CHECK(root->child[1]->child[1]->window == 1);
    CHECK(frame(p, 3).y == frame(p, 1).y);
    CHECK(e.model().check_invariants());
}

TEST_CASE("bad arguments leave the tree alone") {
    Engine e;
    open(e, 2);
    Plan p;
    CHECK(e.move_beside(0, 2, Direction::Left, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.move_beside(1, 0, Direction::Left, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.move_beside(1, 1, Direction::Left, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.move_beside(1, 9, Direction::Left, p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.move_beside(9, 2, Direction::Left, p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.model().find_space(S)->tree.root()->orientation == Orientation::Vertical);
    CHECK(e.model().check_invariants());
}

TEST_CASE("windows on different spaces are refused") {
    Engine e;
    open(e, 2);
    open(e, 1, S2, 2, 10);
    Plan p;
    CHECK(e.move_beside(1, 10, Direction::Left, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.model().tree_space_of(1) == S);
}

TEST_CASE("zoom ends, and the C API rejects a bad side") {
    Engine e;
    open(e, 3);
    Plan p;
    REQUIRE(e.toggle_zoom(2, p) == HM_OK);
    REQUIRE(e.move_beside(1, 3, Direction::Down, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 0);

    hm_engine *h = hm_engine_create(nullptr);
    REQUIRE(h != nullptr);
    hm_plan out{};
    CHECK(hm_engine_move_beside(h, 1, 2, static_cast<hm_direction>(9), &out) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_move_beside(nullptr, 1, 2, HM_DIR_LEFT, &out) == HM_ERR_INVALID_ARGUMENT);
    hm_engine_destroy(h);
}

} // TEST_SUITE

TEST_SUITE("engine: rotate_split") {

TEST_CASE("two windows: side by side becomes stacked and back") {
    Engine e;
    open(e, 2);
    Plan p;
    REQUIRE(e.rotate_split(1, p) == HM_OK);
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 434);
    CHECK_RECT(frame(p, 2), 12, 454, 1416, 434);
    CHECK(e.model().find_space(S)->tree.root()->orientation == Orientation::Horizontal);
    REQUIRE(e.rotate_split(2, p) == HM_OK); // either child flips the same split
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);
}

TEST_CASE("only the parent split of the focused leaf rotates; its ratio is kept") {
    Engine e;
    open(e, 3); // 1 | (2 / 3)
    step(e, 1, Direction::Right);
    Plan p;
    REQUIRE(e.rotate_split(3, p) == HM_OK);
    const Node *root = e.model().find_space(S)->tree.root();
    CHECK(root->orientation == Orientation::Vertical);
    CHECK(root->ratio == doctest::Approx(0.55));
    CHECK(root->child[1]->orientation == Orientation::Vertical); // was Horizontal
    CHECK(root->child[1]->ratio == 0.5);
    CHECK(frame(p, 2).y == frame(p, 3).y); // now side by side
    CHECK(e.model().check_invariants());
}

TEST_CASE("a lone window and bad windows") {
    Engine e;
    open(e, 1);
    Plan p;
    REQUIRE(e.rotate_split(1, p) == HM_OK);
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
    CHECK(e.rotate_split(0, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.rotate_split(5, p) == HM_ERR_UNKNOWN_WINDOW);
}

} // TEST_SUITE

TEST_SUITE("engine: zoom") {

TEST_CASE("zoom fills the outer-gap rectangle, the rest of the tree keeps its frames") {
    Config c;
    c.outer_gap = 30;
    Engine e(c);
    open(e, 3);
    const LayoutResult tree = e.layout_of(S);
    Plan p;
    REQUIRE(e.toggle_zoom(2, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 2);
    CHECK_RECT(frame(p, 2), 30, 30, 1380, 840);
    CHECK(frame(p, 1) == frame(tree, 1));
    CHECK(frame(p, 3) == frame(tree, 3));
    CHECK(p.placements.size() == 3);
    // layout_of is the pure tree layout.
    CHECK(frame(e.layout_of(S), 2) == frame(tree, 2));
    REQUIRE(e.toggle_zoom(2, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 0);
    for (WindowId w : {1, 2, 3}) CHECK(frame(p, w) == frame(tree, w));
}

TEST_CASE("zooming another window moves the zoom") {
    Engine e;
    open(e, 3);
    Plan p;
    REQUIRE(e.toggle_zoom(1, p) == HM_OK);
    REQUIRE(e.toggle_zoom(3, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 3);
    CHECK_RECT(frame(p, 3), 12, 12, 1416, 876);
    CHECK(frame(p, 1) == frame(e.layout_of(S), 1));
}

TEST_CASE("a lone window cannot be zoomed, unknown windows are rejected") {
    Engine e;
    open(e, 1);
    Plan p;
    REQUIRE(e.toggle_zoom(1, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 0);
    CHECK(e.toggle_zoom(0, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.toggle_zoom(9, p) == HM_ERR_UNKNOWN_WINDOW);
}

TEST_CASE("zoom survives reconciles that change nothing, and a focus on the zoomed window or none") {
    Engine e;
    open(e, 3);
    Plan p;
    REQUIRE(e.toggle_zoom(2, p) == HM_OK);
    p = reconcile_ok(e, snap(S, {{1}, {2}, {3}}, 2));
    CHECK(e.zoomed_window(S) == 2);
    CHECK_RECT(frame(p, 2), 12, 12, 1416, 876);
    reconcile_ok(e, snap(S, {{1}, {2}, {3}}, 0));
    CHECK(e.zoomed_window(S) == 2);
    reconcile_ok(e, snap(S, {{1}, {2}, {3}, {4, St::Floating}}, 4)); // focus on a window outside the tree
    CHECK(e.zoomed_window(S) == 2);
}

TEST_CASE("zoom clears when focus moves to another tile") {
    Engine e;
    open(e, 3);
    Plan p;
    REQUIRE(e.toggle_zoom(2, p) == HM_OK);
    p = reconcile_ok(e, snap(S, {{1}, {2}, {3}}, 3));
    CHECK(e.zoomed_window(S) == 0);
    CHECK(frame(p, 2) == frame(e.layout_of(S), 2));
}

TEST_CASE("zoom clears when the window closes, is minimized or moves away") {
    for (int how = 0; how < 3; ++how) {
        CAPTURE(how);
        Engine e;
        open(e, 3);
        Plan p;
        REQUIRE(e.toggle_zoom(2, p) == HM_OK);
        if (how == 0) p = reconcile_ok(e, snap(S, {{1}, {3}}));
        if (how == 1) p = reconcile_ok(e, snap(S, {{1}, {2, St::Minimized}, {3}}));
        if (how == 2) {
            reconcile_ok(e, snap(S2, {{2}}, 0, kUsable, 2));
            p = reconcile_ok(e, snap(S, {{1}, {3}}));
        }
        CHECK(e.zoomed_window(S) == 0);
        CHECK(p.placements.size() == 2);
        // Back from the ghost: no stale zoom either.
        if (how == 1) {
            p = reconcile_ok(e, snap(S, {{1}, {2}, {3}}));
            CHECK(e.zoomed_window(S) == 0);
            CHECK(p.placements.size() == 3);
            CHECK(frame(p, 2) == frame(e.layout_of(S), 2));
        }
    }
}

TEST_CASE("zoom clears when a window joins, and on resize, rotate, equalize and swap") {
    auto zoomed = [] {
        auto e = std::make_unique<Engine>();
        open(*e, 3);
        Plan p;
        REQUIRE(e->toggle_zoom(2, p) == HM_OK);
        return e;
    };
    { auto e = zoomed(); reconcile_ok(*e, snap(S, {{4}, {1}, {2}, {3}}, 2)); CHECK(e->zoomed_window(S) == 0); }
    { auto e = zoomed(); step(*e, 2, Direction::Left); CHECK(e->zoomed_window(S) == 0); }
    { auto e = zoomed(); Plan p; REQUIRE(e->rotate_split(2, p) == HM_OK); CHECK(e->zoomed_window(S) == 0); }
    { auto e = zoomed(); Plan p; REQUIRE(e->equalize(S, p) == HM_OK); CHECK(e->zoomed_window(S) == 0); }
    { auto e = zoomed(); Plan p; REQUIRE(e->swap(1, 3, p) == HM_OK); CHECK(e->zoomed_window(S) == 0); }
    { auto e = zoomed(); Plan p; const Rect f = frame(e->layout_of(S), 2);
      REQUIRE(e->resize(2, {f.x, f.y, f.w + 30, f.h}, p) == HM_OK); CHECK(e->zoomed_window(S) == 0); }
}

TEST_CASE("zoom is per space and clear_zoom clears one or all") {
    Engine e;
    open(e, 2, S);
    open(e, 2, S2, 2, 10);
    Plan p;
    REQUIRE(e.toggle_zoom(1, p) == HM_OK);
    REQUIRE(e.toggle_zoom(10, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 1);
    CHECK(e.zoomed_window(S2) == 10);
    e.clear_zoom(S);
    CHECK(e.zoomed_window(S) == 0);
    CHECK(e.zoomed_window(S2) == 10);
    REQUIRE(e.toggle_zoom(1, p) == HM_OK);
    e.clear_zoom(0);
    CHECK(e.zoomed_window(S) == 0);
    CHECK(e.zoomed_window(S2) == 0);
    CHECK(e.zoomed_window(404) == 0);
}

TEST_CASE("relayout keeps the zoom; a forgotten zoomed window ends it") {
    Engine e;
    open(e, 3);
    Plan p;
    REQUIRE(e.toggle_zoom(2, p) == HM_OK);
    REQUIRE(e.relayout(S, p) == HM_OK);
    CHECK_RECT(frame(p, 2), 12, 12, 1416, 876);
    e.forget_window(2);
    REQUIRE(e.relayout(S, p) == HM_OK);
    CHECK(e.zoomed_window(S) == 0);
    CHECK(p.placements.size() == 2);
}

} // TEST_SUITE

TEST_SUITE("engine: move_to_space") {

TEST_CASE("the window leaves one tree, joins the other and both spaces reflow") {
    Engine e;
    open(e, 2, S, 1, 1);
    open(e, 1, S2, 2, 10);
    Plan to, from;
    REQUIRE(e.move_to_space(2, S2, to, from) == HM_OK);
    CHECK(to.space == S2);
    CHECK(from.space == S);
    REQUIRE(to.placements.size() == 2);
    CHECK(has(to, 10));
    CHECK(has(to, 2));
    REQUIRE(from.placements.size() == 1);
    CHECK_RECT(frame(from, 1), 12, 12, 1416, 876);
    CHECK(e.space_of(2) == S2);
    CHECK(e.tiled_count(S) == 1);
    CHECK(e.tiled_count(S2) == 2);
    CHECK(from.revision > to.revision);
    std::string why;
    CHECK_MESSAGE(e.model().check_invariants(&why), why);
    // The next reconcile of each display agrees: nothing moves.
    const Plan again = reconcile_ok(e, snap(S2, {{2}, {10}}, 2, kUsable, 2));
    CHECK(frame(again, 2) == frame(to, 2));
    CHECK(frame(again, 10) == frame(to, 10));
}

TEST_CASE("the last window of a space can move out and into an empty tree") {
    Engine e;
    open(e, 1, S, 1, 1);
    reconcile_ok(e, snap(S2, {{50, St::Floating}}, 0, kUsable, 2)); // known, empty tree
    Plan to, from;
    REQUIRE(e.move_to_space(1, S2, to, from) == HM_OK);
    CHECK_RECT(frame(to, 1), 12, 12, 1416, 876);
    CHECK(from.placements.empty());
    CHECK(e.tiled_count(S) == 0);
}

TEST_CASE("moving clears zoom on both spaces") {
    Engine e;
    open(e, 3, S, 1, 1);
    open(e, 2, S2, 2, 10);
    Plan p, to, from;
    REQUIRE(e.toggle_zoom(1, p) == HM_OK);
    REQUIRE(e.toggle_zoom(10, p) == HM_OK);
    REQUIRE(e.move_to_space(2, S2, to, from) == HM_OK);
    CHECK(e.zoomed_window(S) == 0);
    CHECK(e.zoomed_window(S2) == 0);
}

TEST_CASE("move_to_space errors leave the engine untouched") {
    Engine e;
    open(e, 2, S, 1, 1);
    open(e, 1, S2, 2, 10);
    Plan to, from;
    CHECK(e.move_to_space(0, S2, to, from) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.move_to_space(1, 0, to, from) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.move_to_space(1, S, to, from) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.move_to_space(1, 999, to, from) == HM_ERR_UNKNOWN_SPACE);
    CHECK(e.move_to_space(77, S2, to, from) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.tiled_count(S) == 2);
    CHECK(e.tiled_count(S2) == 1);
}

} // TEST_SUITE

TEST_SUITE("c api: keyboard actions") {

namespace {
struct Guard {
    hm_engine *e = hm_engine_create(nullptr);
    ~Guard() { hm_engine_destroy(e); }
};
hm_plan reconcile_c(hm_engine *e, hm_space_id space, hm_display_id display, std::vector<hm_window_id> ids,
                    hm_window_id focused = 0) {
    std::vector<hm_window_info> ws;
    for (hm_window_id id : ids) {
        hm_window_info w{};
        w.id = id;
        ws.push_back(w);
    }
    hm_space_snapshot s{display, space, {0, 0, 1440, 900}, focused, ws.data(), ws.size()};
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(e, &s, &p) == HM_OK);
    return p;
}
} // namespace

TEST_CASE("every action round-trips through the C API and frees its plans") {
    const long before = diag::live_plan_buffers();
    {
        Guard g;
        hm_plan p = reconcile_c(g.e, 5, 1, {2, 1});
        hm_plan_free(&p);
        hm_plan_free(&p);

        REQUIRE(hm_engine_resize_step(g.e, 1, HM_DIR_RIGHT, &p) == HM_OK);
        REQUIRE(p.count == 2);
        CHECK(p.placements[0].frame.w == doctest::Approx(774.4));
        hm_plan_free(&p);

        REQUIRE(hm_engine_rotate_split(g.e, 1, &p) == HM_OK);
        CHECK(p.placements[0].frame.w == 1416);
        hm_plan_free(&p);

        REQUIRE(hm_engine_equalize(g.e, 5, &p) == HM_OK);
        CHECK(p.placements[0].frame.h == 434);
        hm_plan_free(&p);

        REQUIRE(hm_engine_toggle_zoom(g.e, 2, &p) == HM_OK);
        CHECK(hm_engine_zoomed_window(g.e, 5) == 2);
        hm_plan_free(&p);
        hm_engine_clear_zoom(g.e, 0);
        CHECK(hm_engine_zoomed_window(g.e, 5) == 0);

        hm_plan other = reconcile_c(g.e, 6, 2, {9});
        hm_plan_free(&other);
        hm_plan to{}, from{};
        REQUIRE(hm_engine_move_to_space(g.e, 2, 6, &to, &from) == HM_OK);
        CHECK(to.count == 2);
        CHECK(from.count == 1);
        hm_plan_free(&to);
        hm_plan_free(&from);
    }
    CHECK(diag::live_plan_buffers() == before);
}

TEST_CASE("argument checks") {
    Guard g;
    hm_plan p{}, q{};
    CHECK(hm_engine_resize_step(nullptr, 1, HM_DIR_LEFT, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_resize_step(g.e, 1, HM_DIR_LEFT, nullptr) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_resize_step(g.e, 1, static_cast<hm_direction>(42), &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_resize_step(g.e, 1, HM_DIR_LEFT, &p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_equalize(g.e, 5, &p) == HM_ERR_UNKNOWN_SPACE);
    CHECK(hm_engine_equalize(nullptr, 5, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_rotate_split(g.e, 1, &p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_toggle_zoom(g.e, 1, &p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_toggle_zoom(nullptr, 1, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_zoomed_window(nullptr, 5) == 0);
    hm_engine_clear_zoom(nullptr, 0);
    CHECK(hm_engine_move_to_space(g.e, 1, 6, &p, &q) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_move_to_space(g.e, 1, 6, nullptr, &q) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_move_to_space(g.e, 1, 6, &p, nullptr) == HM_ERR_INVALID_ARGUMENT);
}

} // TEST_SUITE
