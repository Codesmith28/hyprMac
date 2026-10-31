#include "engine_support.hpp"

#include <limits>
#include <vector>

using namespace hypr;
using namespace hypr::test;

namespace {

constexpr SpaceId S1 = 101;
constexpr SpaceId S2 = 202;

// Open windows 1..n on `space` one reconcile at a time (newest in front, no focus).
Plan build(Engine &e, SpaceId space, int n, Rect usable = kUsable, DisplayId display = 1) {
    Plan p;
    for (int k = 1; k <= n; ++k) {
        Snapshot s = snap(space, {}, 0, usable, display);
        for (int w = k; w >= 1; --w) s.windows.push_back({static_cast<WindowId>(w), St::Tiled, {}, 0, 0});
        p = reconcile_ok(e, s);
    }
    return p;
}

std::vector<WindowId> ids(const Plan &p) {
    std::vector<WindowId> out;
    for (const auto &pl : p.placements) out.push_back(pl.id);
    return out;
}

void check_same_frames(const Plan &a, const Plan &b) {
    REQUIRE(a.placements.size() == b.placements.size());
    for (const auto &pl : a.placements) CHECK_RECT(frame(b, pl.id), pl.frame.x, pl.frame.y, pl.frame.w, pl.frame.h);
}

} // namespace

TEST_SUITE("engine: dwindle") {

TEST_CASE("1 to 4 windows, exact rectangles") {
    Engine e;
    Plan p = build(e, S1, 1);
    CHECK(p.space == S1);
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);

    p = build(e, S2, 2);
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);

    Engine e3;
    p = build(e3, S1, 3);
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 434);
    CHECK_RECT(frame(p, 3), 724, 454, 704, 434);

    Engine e4;
    p = build(e4, S1, 4);
    CHECK(ids(p) == std::vector<WindowId>{1, 2, 3, 4});
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 434);
    CHECK_RECT(frame(p, 3), 724, 454, 348, 434);
    CHECK_RECT(frame(p, 4), 1080, 454, 348, 434);
}

TEST_CASE("5 and 8 windows stay sound") {
    for (int n : {5, 8}) {
        CAPTURE(n);
        Engine e;
        const Plan p = build(e, S1, n);
        CHECK(p.placements.size() == static_cast<std::size_t>(n));
        const LayoutResult l = e.layout_of(S1);
        CHECK(layout_problem(l, kUsable, 12) == "");
        CHECK(l.gap_area == doctest::Approx(expected_gap_area(e.model().find_space(S1)->tree.root(), l, 8)));
    }
    Engine e;
    const Plan p = build(e, S1, 5);
    CHECK_RECT(frame(p, 5), 1080, 675, 348, 213);
}

TEST_CASE("portrait display stacks the second window") {
    Engine e;
    const Plan p = build(e, S1, 2, {0, 0, 1080, 1920});
    CHECK_RECT(frame(p, 1), 12, 12, 1056, 944);
    CHECK_RECT(frame(p, 2), 12, 964, 1056, 944);
}

TEST_CASE("a square leaf splits side by side") {
    Engine e;
    const Plan p = build(e, S1, 2, {0, 0, 1024, 1024});
    CHECK_RECT(frame(p, 1), 12, 12, 496, 1000);
    CHECK_RECT(frame(p, 2), 516, 12, 496, 1000);
}

TEST_CASE("target: the focused leaf") {
    Engine e;
    build(e, S1, 2);
    const Plan p = reconcile_ok(e, snap(S1, {{3}, {2}, {1}}, /*focused*/ 1));
    CHECK_RECT(frame(p, 1), 12, 12, 704, 434);
    CHECK_RECT(frame(p, 3), 12, 454, 704, 434);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);
}

TEST_CASE("target: a focused window that is itself new is ignored") {
    Engine e;
    build(e, S1, 2);
    const Plan p = reconcile_ok(e, snap(S1, {{3}, {2}, {1}}, /*focused*/ 3));
    CHECK_RECT(frame(p, 2), 724, 12, 704, 434); // most recently inserted (2) was split
    CHECK_RECT(frame(p, 3), 724, 454, 704, 434);
}

TEST_CASE("target: an unknown focused window is ignored") {
    Engine e;
    build(e, S1, 2);
    const Plan p = reconcile_ok(e, snap(S1, {{3}, {2}, {1}}, /*focused*/ 999));
    CHECK_RECT(frame(p, 3), 724, 454, 704, 434);
}

TEST_CASE("target: a focused window tiled on another space is ignored") {
    Engine e;
    reconcile_ok(e, snap(S2, {{50}}));
    build(e, S1, 2);
    const Plan p = reconcile_ok(e, snap(S1, {{3}, {2}, {1}}, /*focused*/ 50));
    CHECK_RECT(frame(p, 3), 724, 454, 704, 434);
    CHECK(e.space_of(50) == S2);
}

TEST_CASE("several new windows are inserted back to front") {
    Engine e;
    const Plan p = reconcile_ok(e, snap(S1, {{1}, {2}, {3}}, /*focused*/ 1));
    CHECK(ids(p) == std::vector<WindowId>{3, 2, 1});
    CHECK_RECT(frame(p, 3), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 434);
    CHECK_RECT(frame(p, 1), 724, 454, 704, 434);
}

TEST_CASE("several new windows around an existing focused leaf") {
    Engine e;
    reconcile_ok(e, snap(S1, {{10}}));
    const Plan p = reconcile_ok(e, snap(S1, {{1}, {2}, {10}}, /*focused*/ 10));
    CHECK(ids(p) == std::vector<WindowId>{10, 1, 2});
    CHECK_RECT(frame(p, 10), 12, 12, 704, 434);
    CHECK_RECT(frame(p, 1), 12, 454, 704, 434);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);
}

TEST_CASE("target: front-most existing leaf when the last inserted window closed") {
    Engine e;
    build(e, S1, 3); // 1 | (2 / 3), last inserted 3
    const Plan p = reconcile_ok(e, snap(S1, {{4}, {2}, {1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 434);
    CHECK_RECT(frame(p, 4), 724, 454, 704, 434);
}

} // TEST_SUITE

TEST_SUITE("engine: removal") {

TEST_CASE("closing windows promotes siblings") {
    Engine e;
    build(e, S1, 3);
    Plan p = reconcile_ok(e, snap(S1, {{1}, {3}}));
    CHECK_RECT(frame(p, 3), 724, 12, 704, 876);
    p = reconcile_ok(e, snap(S1, {{3}}));
    CHECK_RECT(frame(p, 3), 12, 12, 1416, 876);
    CHECK(e.space_of(1) == 0);
    p = reconcile_ok(e, snap(S1, {}));
    CHECK(p.placements.empty());
    CHECK(e.tiled_count(S1) == 0);
    CHECK(e.space_of(3) == 0);
}

TEST_CASE("closing the root's first child promotes the whole sibling subtree") {
    Engine e;
    build(e, S1, 3);
    const Plan p = reconcile_ok(e, snap(S1, {{2}, {3}}));
    CHECK_RECT(frame(p, 2), 12, 12, 1416, 434);
    CHECK_RECT(frame(p, 3), 12, 454, 1416, 434);
}

TEST_CASE("forget_window drops a window everywhere") {
    Engine e;
    build(e, S1, 3);
    reconcile_ok(e, snap(S1, {{1}, {2}, {3, St::Minimized}}));
    REQUIRE(e.space_of(3) == S1);
    e.forget_window(3);
    e.forget_window(2);
    e.forget_window(0);
    e.forget_window(12345);
    CHECK(e.space_of(3) == 0);
    CHECK(e.space_of(2) == 0);
    CHECK(e.tiled_count(S1) == 1);
    CHECK(e.model().ghost_count() == 0);
    CHECK(e.model().check_invariants());
}

TEST_CASE("forget_space drops the tree") {
    Engine e;
    build(e, S1, 2);
    e.forget_space(S1);
    e.forget_space(999);
    CHECK(e.tiled_count(S1) == 0);
    CHECK(e.space_of(1) == 0);
    Plan p;
    CHECK(e.relayout(S1, p) == HM_ERR_UNKNOWN_SPACE);
    CHECK(e.model().check_invariants());
}

} // TEST_SUITE

TEST_SUITE("engine: ghosts") {

TEST_CASE("minimize then restore gives back the exact rectangles, for every leaf") {
    for (WindowId victim = 1; victim <= 4; ++victim) {
        CAPTURE(victim);
        Engine e;
        const Plan before = build(e, S1, 4);
        Snapshot s = snap(S1, {{4}, {3}, {2}, {1}});
        for (auto &w : s.windows)
            if (w.id == victim) w.state = St::Minimized;
        Plan p = reconcile_ok(e, s);
        CHECK(p.placements.size() == 3);
        CHECK_FALSE(has(p, victim));
        CHECK(e.space_of(victim) == S1);
        CHECK(e.tiled_count(S1) == 3);
        CHECK(layout_problem(e.layout_of(S1), kUsable, 12) == "");

        p = reconcile_ok(e, snap(S1, {{4}, {3}, {2}, {1}}));
        check_same_frames(before, p);
        CHECK(e.model().ghost_count() == 0);
    }
}

TEST_CASE("minimizing the only window and restoring it") {
    Engine e;
    build(e, S1, 1);
    Plan p = reconcile_ok(e, snap(S1, {{1, St::Minimized}}));
    CHECK(p.placements.empty());
    CHECK(e.space_of(1) == S1);
    p = reconcile_ok(e, snap(S1, {{1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
}

TEST_CASE("a ghost survives while its window is absent from the snapshot") {
    Engine e;
    const Plan before = build(e, S1, 3);
    reconcile_ok(e, snap(S1, {{1}, {2}, {3, St::Minimized}}));
    reconcile_ok(e, snap(S1, {{1}, {2}}));
    CHECK(e.space_of(3) == S1);
    const Plan p = reconcile_ok(e, snap(S1, {{3}, {2}, {1}}));
    check_same_frames(before, p);
}

TEST_CASE("fullscreen window appearing in another space's snapshot") {
    Engine e;
    const Plan before = build(e, S1, 2);
    constexpr SpaceId kFullscreenSpace = 909;

    Plan p = reconcile_ok(e, snap(kFullscreenSpace, {{2, St::Fullscreen}}, 2));
    CHECK(p.space == kFullscreenSpace);
    CHECK(p.placements.empty());
    CHECK(e.tiled_count(S1) == 1);
    CHECK(e.space_of(2) == S1); // ghost recorded against the ORIGINAL space
    REQUIRE(e.model().ghost(2) != nullptr);
    CHECK(e.model().ghost(2)->space == S1);

    p = reconcile_ok(e, snap(S1, {{1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
    CHECK(e.space_of(2) == S1);

    e.forget_space(kFullscreenSpace); // the fullscreen Space is destroyed on exit
    CHECK(e.space_of(2) == S1);

    p = reconcile_ok(e, snap(S1, {{2}, {1}}, 2));
    check_same_frames(before, p);
}

TEST_CASE("hiding an app with two windows restores both (either snapshot order)") {
    for (bool reversed : {false, true}) {
        CAPTURE(reversed);
        Engine e;
        const Plan before = build(e, S1, 3); // 1 | (2 / 3); 2 and 3 belong to one app
        const Snapshot hidden = reversed ? snap(S1, {{3, St::Hidden}, {2, St::Hidden}, {1}})
                                         : snap(S1, {{1}, {2, St::Hidden}, {3, St::Hidden}});
        Plan p = reconcile_ok(e, hidden);
        CHECK(ids(p) == std::vector<WindowId>{1});
        CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
        CHECK(e.model().ghost_count() == 2);

        p = reconcile_ok(e, snap(S1, {{1}, {2}, {3}}, 1));
        check_same_frames(before, p);
        CHECK(e.model().ghost_count() == 0);
    }
}

TEST_CASE("a ghost whose sibling closed falls back to dwindle insertion") {
    Engine e;
    build(e, S1, 3); // 1 | (2 / 3)
    reconcile_ok(e, snap(S1, {{1}, {2}, {3, St::Minimized}}));
    REQUIRE(e.model().ghost(3)->sibling == 2);
    reconcile_ok(e, snap(S1, {{1}, {3, St::Minimized}})); // 2 closed
    const Plan p = reconcile_ok(e, snap(S1, {{3}, {1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 3), 724, 12, 704, 876);
    CHECK(e.model().ghost(3) == nullptr);
}

TEST_CASE("a restore re-splits only the sibling leaf when the sibling subtree changed") {
    Engine e;
    build(e, S1, 2); // 1 | 2
    reconcile_ok(e, snap(S1, {{1, St::Minimized}, {2}}));
    reconcile_ok(e, snap(S1, {{5}, {2}}, 2)); // 2 | 5 now fills the screen
    const Plan p = reconcile_ok(e, snap(S1, {{1}, {5}, {2}}));
    // Window 1 was first, vertical, beside window 2: only 2's leaf is re-split.
    CHECK_RECT(frame(p, 1), 12, 12, 348, 876);
    CHECK_RECT(frame(p, 2), 368, 12, 348, 876);
    CHECK_RECT(frame(p, 5), 724, 12, 704, 876);
}

TEST_CASE("a ghost recorded against a forgotten space") {
    Engine e;
    build(e, S1, 2);
    reconcile_ok(e, snap(S1, {{1}, {2, St::Minimized}}));
    e.forget_space(S1);
    CHECK(e.space_of(2) == 0);
    CHECK(e.model().ghost_count() == 0);
    const Plan p = reconcile_ok(e, snap(S2, {{2}}));
    CHECK_RECT(frame(p, 2), 12, 12, 1416, 876);
    CHECK(e.space_of(2) == S2);
}

TEST_CASE("a ghosted window that returns on another space is inserted there") {
    Engine e;
    build(e, S1, 2);
    reconcile_ok(e, snap(S1, {{1}, {2, St::Minimized}}));
    reconcile_ok(e, snap(S2, {{7}}));
    const Plan p = reconcile_ok(e, snap(S2, {{2}, {7}}));
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);
    CHECK(e.space_of(2) == S2);
    CHECK(e.model().ghost(2) == nullptr);
}

TEST_CASE("windows that were never tiled get no ghost") {
    Engine e;
    const Plan p = reconcile_ok(e, snap(S1, {{1}, {9, St::Minimized}, {8, St::Hidden}, {7, St::Fullscreen}}));
    CHECK(ids(p) == std::vector<WindowId>{1});
    CHECK(e.space_of(9) == 0);
    CHECK(e.model().ghost_count() == 0);
}

} // TEST_SUITE

TEST_SUITE("engine: moves and floating") {

TEST_CASE("a window moved between spaces") {
    Engine e;
    build(e, S1, 2);
    Plan p = reconcile_ok(e, snap(S2, {{2}}));
    CHECK_RECT(frame(p, 2), 12, 12, 1416, 876);
    CHECK(e.space_of(2) == S2);
    CHECK(e.tiled_count(S1) == 1);
    CHECK(e.model().ghost_count() == 0);
    p = reconcile_ok(e, snap(S1, {{1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
}

TEST_CASE("a window moved between displays uses the new usable rect") {
    Engine e;
    build(e, S1, 2);
    const Rect left{-1920, 25, 1920, 1055};
    reconcile_ok(e, snap(S2, {{30}}, 0, left, 2));
    const Plan p = reconcile_ok(e, snap(S2, {{2}, {30}}, 30, left, 2));
    CHECK_RECT(frame(p, 30), -1908, 37, 944, 1031);
    CHECK_RECT(frame(p, 2), -956, 37, 944, 1031);
    CHECK(e.model().find_space(S2)->display == 2);
}

TEST_CASE("the stored usable rect and display follow the latest snapshot") {
    Engine e;
    build(e, S1, 1);
    reconcile_ok(e, snap(S1, {{1}}, 0, {0, 0, 1920, 1080}, 3));
    const Space *sp = e.model().find_space(S1);
    CHECK(sp->usable == Rect{0, 0, 1920, 1080});
    CHECK(sp->display == 3);
    Plan p;
    REQUIRE(e.relayout(S1, p) == HM_OK);
    CHECK_RECT(frame(p, 1), 12, 12, 1896, 1056);
}

TEST_CASE("toggling a window between tiled and floating") {
    Engine e;
    const Plan before = build(e, S1, 2);
    Plan p = reconcile_ok(e, snap(S1, {{1}, {2, St::Floating}}));
    CHECK(ids(p) == std::vector<WindowId>{1});
    CHECK(e.space_of(2) == 0);
    CHECK(e.model().ghost_count() == 0);
    p = reconcile_ok(e, snap(S1, {{2}, {1}}));
    check_same_frames(before, p);
}

TEST_CASE("a floating window drops its ghost") {
    Engine e;
    build(e, S1, 2);
    reconcile_ok(e, snap(S1, {{1}, {2, St::Minimized}}));
    reconcile_ok(e, snap(S1, {{1}, {2, St::Floating}}));
    CHECK(e.space_of(2) == 0);
    CHECK(e.model().ghost_count() == 0);
}

TEST_CASE("floating in another space's snapshot removes the window from its tree") {
    Engine e;
    build(e, S1, 2);
    reconcile_ok(e, snap(S2, {{2, St::Floating}}));
    CHECK(e.tiled_count(S1) == 1);
    CHECK(e.space_of(2) == 0);
}

} // TEST_SUITE

TEST_SUITE("engine: swap") {

TEST_CASE("swap on the same space exchanges rectangles") {
    Engine e;
    const Plan before = build(e, S1, 3);
    Plan p;
    REQUIRE(e.swap(1, 3, p) == HM_OK);
    CHECK(p.space == S1);
    CHECK(p.revision > before.revision);
    const Rect f1 = frame(before, 1), f3 = frame(before, 3);
    CHECK_RECT(frame(p, 3), f1.x, f1.y, f1.w, f1.h);
    CHECK_RECT(frame(p, 1), f3.x, f3.y, f3.w, f3.h);
    REQUIRE(e.swap(2, 2, p) == HM_OK);
    CHECK(e.model().check_invariants());
}

TEST_CASE("swap rejects cross-space, unknown, ghosted and zero ids") {
    Engine e;
    build(e, S1, 2);
    reconcile_ok(e, snap(S2, {{9}, {8, St::Floating}}));
    reconcile_ok(e, snap(S1, {{1}, {2}, {3}}));
    reconcile_ok(e, snap(S1, {{1}, {2}, {3, St::Minimized}}));
    const std::uint64_t rev = e.last_revision();
    Plan p;
    CHECK(e.swap(1, 9, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.swap(1, 77, p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.swap(77, 1, p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.swap(1, 3, p) == HM_ERR_UNKNOWN_WINDOW); // ghosted
    CHECK(e.swap(1, 8, p) == HM_ERR_UNKNOWN_WINDOW); // floating
    CHECK(e.swap(0, 1, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.last_revision() == rev);
}

} // TEST_SUITE

TEST_SUITE("engine: min size and config") {

TEST_CASE("report_min_size followed by relayout") {
    Engine e;
    build(e, S1, 2);
    REQUIRE(e.report_min_size(1, 900, 0) == HM_OK);
    Plan p;
    REQUIRE(e.relayout(S1, p) == HM_OK);
    CHECK_RECT(frame(p, 1), 12, 12, 900, 876);
    CHECK_RECT(frame(p, 2), 920, 12, 508, 876);
    CHECK(e.model().find_space(S1)->tree.root()->ratio == 0.5);
}

TEST_CASE("report_min_size validation") {
    Engine e;
    build(e, S1, 1);
    const double nan = std::numeric_limits<double>::quiet_NaN();
    CHECK(e.report_min_size(0, 1, 1) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.report_min_size(1, nan, 1) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.report_min_size(1, 1, std::numeric_limits<double>::infinity()) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.report_min_size(1, -1, 1) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.report_min_size(42, 1, 1) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.min_size(1).w == 0);
}

TEST_CASE("snapshot min-size hints and reports combine per axis") {
    Engine e;
    reconcile_ok(e, snap(S1, {{1}}));
    Plan p = reconcile_ok(e, snap(S1, {{2, St::Tiled, 1000, 0}, {1}}));
    CHECK_RECT(frame(p, 2), 428, 12, 1000, 876);
    REQUIRE(e.report_min_size(2, 300, 500) == HM_OK);
    CHECK(e.min_size(2).w == 1000);
    CHECK(e.min_size(2).h == 500);
    // A hint of 0 means "unknown" and keeps the previous hint.
    p = reconcile_ok(e, snap(S1, {{2}, {1}}));
    CHECK(frame(p, 2).w == doctest::Approx(1000));
}

TEST_CASE("min sizes are forgotten with the window") {
    Engine e;
    build(e, S1, 2);
    REQUIRE(e.report_min_size(2, 1000, 0) == HM_OK);
    reconcile_ok(e, snap(S1, {{1}})); // 2 closed
    CHECK(e.min_size(2).w == 0);
    const Plan p = reconcile_ok(e, snap(S1, {{2}, {1}}));
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);
}

TEST_CASE("set_config then relayout") {
    Engine e;
    build(e, S1, 2);
    REQUIRE(e.set_config({0, 0, 0.3}) == HM_OK);
    Plan p;
    REQUIRE(e.relayout(S1, p) == HM_OK);
    CHECK_RECT(frame(p, 1), 0, 0, 720, 900); // existing splits keep their ratio
    p = reconcile_ok(e, snap(S1, {{3}, {2}, {1}}));
    CHECK_RECT(frame(p, 2), 720, 0, 720, 270); // new split uses the new ratio
    CHECK(e.set_config({-1, 0, 0.5}) == HM_ERR_CONFIG);
    CHECK(e.set_config({0, 0, 0.95}) == HM_ERR_CONFIG);
    CHECK(e.config().split_ratio == 0.3);
}

} // TEST_SUITE

TEST_SUITE("engine: input and revisions") {

TEST_CASE("duplicate ids in a snapshot: the first occurrence wins") {
    Engine e;
    Plan p = reconcile_ok(e, snap(S1, {{1}, {1, St::Minimized}, {2}, {2}}));
    CHECK(ids(p) == std::vector<WindowId>{2, 1});
    p = reconcile_ok(e, snap(S1, {{1, St::Minimized}, {1}, {2}}));
    CHECK(ids(p) == std::vector<WindowId>{2});
    CHECK(e.model().ghost(1) != nullptr);
}

TEST_CASE("invalid snapshots leave the engine untouched") {
    Engine e;
    build(e, S1, 3);
    reconcile_ok(e, snap(S1, {{1}, {2}, {3, St::Minimized}}));
    const std::string dump = e.debug_dump(S1);
    const std::uint64_t rev = e.last_revision();
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();

    std::vector<Snapshot> bad;
    bad.push_back(snap(S1, {{4}, {0}}));                             // window id 0
    bad.push_back(snap(0, {{4}}));                                   // space id 0
    bad.push_back(snap(S1, {{4}}, 0, {nan, 0, 100, 100}));           // NaN usable
    bad.push_back(snap(S1, {{4}}, 0, {0, 0, inf, 100}));             // infinite usable
    bad.push_back(snap(S1, {{4}}, 0, {0, 0, 1e12, 100}));            // absurd usable
    bad.push_back(snap(S1, {{4, St::Tiled, nan, 0}}));               // NaN min size
    Snapshot frame_nan = snap(S1, {{4}, {1}});
    frame_nan.windows[1].frame.h = nan;                              // NaN frame
    bad.push_back(frame_nan);
    Snapshot bad_state = snap(S1, {{4}});
    bad_state.windows[0].state = static_cast<WindowState>(9);
    bad.push_back(bad_state);

    for (std::size_t i = 0; i < bad.size(); ++i) {
        CAPTURE(i);
        Plan p;
        p.revision = 4242;
        CHECK(e.reconcile(bad[i], p) == HM_ERR_INVALID_ARGUMENT);
        CHECK(p.revision == 4242);
        CHECK(e.debug_dump(S1) == dump);
        CHECK(e.last_revision() == rev);
        CHECK(e.space_of(4) == 0);
    }
    CHECK(e.model().find_space(0) == nullptr);
}

TEST_CASE("negative min sizes in a snapshot are treated as unknown") {
    Engine e;
    const Plan p = reconcile_ok(e, snap(S1, {{1, St::Tiled, -50, -1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
    CHECK(e.min_size(1).w == 0);
}

TEST_CASE("revisions increase monotonically across spaces") {
    Engine e;
    const Plan a = reconcile_ok(e, snap(S1, {{1}}));
    const Plan b = reconcile_ok(e, snap(S2, {{2}}));
    Plan c;
    REQUIRE(e.relayout(S1, c) == HM_OK);
    CHECK(a.revision == 1);
    CHECK(b.revision == 2);
    CHECK(c.revision == 3);
    Plan d;
    CHECK(e.relayout(777, d) == HM_ERR_UNKNOWN_SPACE);
    CHECK(e.last_revision() == 3);
    const Plan f = reconcile_ok(e, snap(S2, {}));
    CHECK(f.revision == 4);
    CHECK(f.placements.empty());
    Plan g;
    REQUIRE(e.relayout(S2, g) == HM_OK); // known but empty space
    CHECK(g.placements.empty());
    CHECK(g.revision == 5);
}

TEST_CASE("debug_dump output is stable") {
    Engine e;
    build(e, 7, 4);
    reconcile_ok(e, snap(7, {{1}, {2}, {3}, {4, St::Minimized}}));
    CHECK(e.debug_dump(7) == "space 7 display 1 usable 0,0,1440,900 leaves 3\n"
                             "V 0.5000\n"
                             "  win 0x1 12,12,704,876\n"
                             "  H 0.5000\n"
                             "    win 0x2 724,12,704,434\n"
                             "    win 0x3 724,454,704,434\n"
                             "ghost 0x4 sibling 0x3 second V 0.5000\n");
    CHECK(e.debug_dump(8) == "");
    reconcile_ok(e, snap(9, {}, 0, {-1920, 0, 1920, 1080}, 2));
    CHECK(e.debug_dump(9) == "space 9 display 2 usable -1920,0,1920,1080 leaves 0\n(empty)\n");
    const WindowId big = (WindowId{5} << 32) | 42;
    reconcile_ok(e, snap(10, {{big}}));
    CHECK(e.debug_dump(10) == "space 10 display 1 usable 0,0,1440,900 leaves 1\n"
                              "win 0x50000002a 12,12,1416,876\n");
}

} // TEST_SUITE
