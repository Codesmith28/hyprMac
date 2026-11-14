// smart_gaps and per-display gaps (Engine::set_smart_gaps / set_display_gaps).
#include "engine_support.hpp"

#include <limits>

using namespace hypr;
using namespace hypr::test;

namespace {
constexpr SpaceId S1 = 101;
constexpr SpaceId S2 = 202;

Plan open(Engine &e, SpaceId space, int n, DisplayId display = 1) {
    Plan p;
    for (int k = 1; k <= n; ++k) {
        Snapshot s = snap(space, {}, 0, kUsable, display);
        for (int w = k; w >= 1; --w) s.windows.push_back({static_cast<WindowId>(w), St::Tiled, {}, 0, 0});
        p = reconcile_ok(e, s);
    }
    return p;
}
} // namespace

TEST_SUITE("gaps") {

TEST_CASE("smart_gaps off by default: one window keeps the outer gap") {
    Engine e;
    CHECK_RECT(frame(open(e, S1, 1), 1), 12, 12, 1416, 876);
}

TEST_CASE("smart_gaps: one tiled window fills the usable rect, two windows use the normal gaps") {
    Engine e;
    e.set_smart_gaps(true);
    Plan p = open(e, S1, 1);
    CHECK_RECT(frame(p, 1), 0, 0, 1440, 900);
    p = open(e, S1, 2);
    CHECK_RECT(frame(p, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(p, 2), 724, 12, 704, 876);
}

TEST_CASE("smart_gaps: closing back to one window drops the gaps again") {
    Engine e;
    e.set_smart_gaps(true);
    open(e, S1, 2);
    Snapshot s = snap(S1, {{1, St::Tiled}});
    CHECK_RECT(frame(reconcile_ok(e, s), 1), 0, 0, 1440, 900);
}

TEST_CASE("smart_gaps counts tiled windows only (a floating one does not count)") {
    Engine e;
    e.set_smart_gaps(true);
    Snapshot s = snap(S1, {{1, St::Tiled}, {2, St::Floating}});
    CHECK_RECT(frame(reconcile_ok(e, s), 1), 0, 0, 1440, 900);
}

TEST_CASE("smart_gaps does not change the dwindle split direction of the second window") {
    Engine a, b;
    b.set_smart_gaps(true);
    Plan pa = open(a, S1, 3), pb = open(b, S1, 3);
    for (WindowId w : {1, 2, 3}) {
        CHECK_RECT(frame(pb, w), frame(pa, w).x, frame(pa, w).y, frame(pa, w).w, frame(pa, w).h);
    }
}

TEST_CASE("per-display gaps replace the global gaps on that display only") {
    Engine e;
    REQUIRE(e.set_display_gaps(2, 4, 8) == HM_OK);
    Plan p1 = open(e, S1, 2, 1);
    CHECK_RECT(frame(p1, 1), 12, 12, 704, 876);
    Plan p2 = open(e, S2, 2, 2);
    CHECK_RECT(frame(p2, 1), 8, 8, 710, 884);
    CHECK_RECT(frame(p2, 2), 722, 8, 710, 884);
}

TEST_CASE("per-display gaps: one side may fall back to the global value; clearing restores it") {
    Engine e;
    REQUIRE(e.set_display_gaps(1, -1, 0) == HM_OK); // outer 0, inner global (8)
    Plan p = open(e, S1, 2, 1);
    CHECK_RECT(frame(p, 1), 0, 0, 716, 900);
    CHECK_RECT(frame(p, 2), 724, 0, 716, 900);
    REQUIRE(e.set_display_gaps(1, -1, -1) == HM_OK);
    Plan r;
    REQUIRE(e.relayout(S1, r) == HM_OK);
    CHECK_RECT(frame(r, 1), 12, 12, 704, 876);
}

TEST_CASE("per-display gaps: out-of-range values are rejected") {
    Engine e;
    CHECK(e.set_display_gaps(1, 201, 0) == HM_ERR_CONFIG);
    CHECK(e.set_display_gaps(1, 0, std::numeric_limits<double>::quiet_NaN()) == HM_ERR_CONFIG);
    CHECK(e.set_display_gaps(1, 200, 200) == HM_OK);
}

TEST_CASE("per-display gaps combine with smart_gaps (one window: zero both)") {
    Engine e;
    e.set_smart_gaps(true);
    REQUIRE(e.set_display_gaps(1, 4, 8) == HM_OK);
    CHECK_RECT(frame(open(e, S1, 1), 1), 0, 0, 1440, 900);
    CHECK_RECT(frame(open(e, S1, 2), 1), 8, 8, 710, 884);
}

} // TEST_SUITE
