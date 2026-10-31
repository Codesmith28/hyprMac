#include "engine_support.hpp"

#include "hypr/hypr_core.h"

#include <cmath>
#include <limits>

using namespace hypr;
using namespace hypr::test;

namespace {

constexpr SpaceId S = 7;

// Windows 1..n opened one reconcile at a time (dwindle): 1 | (2 / 3) | ...
Plan open(Engine &e, int n) {
    Plan p;
    for (int k = 1; k <= n; ++k) {
        Snapshot s = snap(S, {});
        for (int w = k; w >= 1; --w) s.windows.push_back({static_cast<WindowId>(w), St::Tiled, {}, 0, 0});
        p = reconcile_ok(e, s);
    }
    return p;
}

} // namespace

TEST_SUITE("engine: user resize") {

TEST_CASE("two windows: dragging the left window's right edge +200") {
    Engine e;
    const Plan before = open(e, 2);
    Rect a = frame(before, 1);
    CHECK_RECT(a, 12, 12, 704, 876);
    Plan p;
    REQUIRE(e.resize(1, {a.x, a.y, a.w + 200, a.h}, p) == HM_OK);
    CHECK(p.space == S);
    CHECK(p.revision > before.revision);
    CHECK_RECT(frame(p, 1), 12, 12, 904, 876);
    CHECK_RECT(frame(p, 2), 924, 12, 504, 876);
    CHECK(e.model().check_invariants());
}

TEST_CASE("two windows: dragging the right window's left edge") {
    Engine e;
    open(e, 2);
    Plan p;
    REQUIRE(e.resize(2, {624, 12, 804, 876}, p) == HM_OK); // left edge 724 -> 624 (-100)
    CHECK_RECT(frame(p, 2), 624, 12, 804, 876);
    CHECK_RECT(frame(p, 1), 12, 12, 604, 876);
}

TEST_CASE("nested: the bottom-right window's top edge moves only the inner horizontal split") {
    Engine e;
    const Plan before = open(e, 3);
    const Rect f1 = frame(before, 1), f2 = frame(before, 2), f3 = frame(before, 3);
    CHECK_RECT(f3, 724, 454, 704, 434);
    Plan p;
    REQUIRE(e.resize(3, {f3.x, f3.y - 100, f3.w, f3.h + 100}, p) == HM_OK);
    CHECK_RECT(frame(p, 3), 724, 354, 704, 534);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 334);
    CHECK_RECT(frame(p, 1), f1.x, f1.y, f1.w, f1.h);
    CHECK(f2.h > frame(p, 2).h);
}

TEST_CASE("nested: left edge of the bottom-right window moves the OUTER vertical split") {
    Engine e;
    const Plan before = open(e, 3);
    const Rect f3 = frame(before, 3);
    Plan p;
    REQUIRE(e.resize(3, {f3.x - 100, f3.y, f3.w + 100, f3.h}, p) == HM_OK);
    CHECK_RECT(frame(p, 3), 624, 454, 804, 434);
    CHECK_RECT(frame(p, 2), 624, 12, 804, 434);
    CHECK_RECT(frame(p, 1), 12, 12, 604, 876);
}

TEST_CASE("clamps to ratio 0.1 / 0.9") {
    Engine e;
    open(e, 2);
    Plan p;
    REQUIRE(e.resize(1, {12, 12, 5000, 876}, p) == HM_OK);
    const double avail = 1416 - 8;
    CHECK(frame(p, 1).w == doctest::Approx(avail * 0.9));
    CHECK(frame(p, 2).w == doctest::Approx(avail * 0.1));
    REQUIRE(e.resize(1, {12, 12, 10, 876}, p) == HM_OK);
    CHECK(frame(p, 1).w == doctest::Approx(avail * 0.1));
}

TEST_CASE("clamps to the minimum size of the neighbour") {
    Engine e;
    Snapshot s = snap(S, {{2, St::Tiled, 0, 0}, {1}});
    s.windows[0].min_w = 600;
    reconcile_ok(e, s);
    Plan p;
    REQUIRE(e.resize(1, {12, 12, 1200, 876}, p) == HM_OK);
    CHECK(frame(p, 2).w >= 600 - 1e-9);
    CHECK(frame(p, 1).w == doctest::Approx(1408 - 600));
}

TEST_CASE("clamps to the window's own minimum size") {
    Engine e;
    Snapshot s = snap(S, {{2}, {1, St::Tiled, 500, 0}});
    reconcile_ok(e, s);
    Plan p;
    REQUIRE(e.resize(1, {12, 12, 300, 876}, p) == HM_OK);
    CHECK(frame(p, 1).w >= 500 - 1e-9);
}

TEST_CASE("an edge with no split on that axis changes nothing") {
    Engine e;
    const Plan before = open(e, 2);
    const Rect a = frame(before, 1);
    Plan p;
    // Left edge of the first child (screen boundary) and vertical edges of a vertical-only split.
    REQUIRE(e.resize(1, {a.x - 100, a.y, a.w + 100, a.h}, p) == HM_OK);
    CHECK_RECT(frame(p, 1), a.x, a.y, a.w, a.h);
    REQUIRE(e.resize(1, {a.x, a.y - 50, a.w, a.h + 50}, p) == HM_OK); // top: no horizontal split
    CHECK_RECT(frame(p, 1), a.x, a.y, a.w, a.h);
    // A lone window has no splits at all.
    Engine e1;
    open(e1, 1);
    REQUIRE(e1.resize(1, {0, 0, 100, 100}, p) == HM_OK);
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
}

TEST_CASE("unknown / invalid arguments") {
    Engine e;
    open(e, 2);
    Plan p;
    CHECK(e.resize(99, {0, 0, 100, 100}, p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(e.resize(0, {0, 0, 100, 100}, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.resize(1, {0, 0, std::numeric_limits<double>::quiet_NaN(), 100}, p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(e.resize(1, {0, 0, std::numeric_limits<double>::infinity(), 100}, p) == HM_ERR_INVALID_ARGUMENT);
    // A ghosted (minimized) window is not tiled.
    reconcile_ok(e, snap(S, {{1, St::Minimized}, {2}}));
    CHECK(e.resize(1, {0, 0, 100, 100}, p) == HM_ERR_UNKNOWN_WINDOW);
}

TEST_CASE("ratios persist across a later reconcile and relayout") {
    Engine e;
    open(e, 2);
    Plan p;
    REQUIRE(e.resize(1, {12, 12, 904, 876}, p) == HM_OK);
    const Plan again = reconcile_ok(e, snap(S, {{2}, {1}}));
    CHECK_RECT(frame(again, 1), 12, 12, 904, 876);
    REQUIRE(e.relayout(S, p) == HM_OK);
    CHECK_RECT(frame(p, 2), 924, 12, 504, 876);
    // A third window splits the focused leaf; the outer ratio is untouched.
    const Plan three = reconcile_ok(e, snap(S, {{3}, {2}, {1}}, 2));
    CHECK_RECT(frame(three, 1), 12, 12, 904, 876);
}

TEST_CASE("C API: hm_engine_resize") {
    hm_engine *e = hm_engine_create(nullptr);
    REQUIRE(e != nullptr);
    hm_window_info ws[2] = {};
    ws[0].id = 2;
    ws[1].id = 1;
    hm_space_snapshot s{};
    s.display = 1;
    s.space = 5;
    s.usable = {0, 0, 1440, 900};
    s.windows = ws;
    s.window_count = 2;
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(e, &s, &p) == HM_OK);
    hm_plan_free(&p);
    REQUIRE(hm_engine_resize(e, 1, {12, 12, 904, 876}, &p) == HM_OK);
    CHECK(p.space == 5);
    REQUIRE(p.count == 2);
    CHECK(p.placements[0].frame.w == doctest::Approx(904));
    CHECK(p.placements[1].frame.x == doctest::Approx(924));
    hm_plan_free(&p);
    CHECK(hm_engine_resize(e, 77, {0, 0, 1, 1}, &p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_resize(e, 1, {0, 0, std::nan(""), 1}, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_resize(nullptr, 1, {0, 0, 1, 1}, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_resize(e, 1, {0, 0, 1, 1}, nullptr) == HM_ERR_INVALID_ARGUMENT);
    hm_engine_destroy(e);
}

} // TEST_SUITE
