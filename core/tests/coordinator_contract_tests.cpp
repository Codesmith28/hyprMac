// Engine behaviour that macos/Sources/HyprKit/Coordinator.swift relies on.
// Each case names the coordinator code path it protects.
#include "engine_support.hpp"

#include <vector>

using namespace hypr;
using namespace hypr::test;

namespace {

constexpr SpaceId SA = 11; // active Space of display 1
constexpr SpaceId SB = 22; // active Space of display 2
const Rect kLeft{-1920, 0, 1920, 1080};

void check_same(const Plan &a, const Plan &b) {
    REQUIRE(a.placements.size() == b.placements.size());
    for (std::size_t i = 0; i < a.placements.size(); ++i) {
        CHECK(a.placements[i].id == b.placements[i].id);
        CHECK(a.placements[i].frame == b.placements[i].frame);
    }
}

Plan relayout_ok(Engine &e, SpaceId s) {
    Plan p;
    REQUIRE(e.relayout(s, p) == HM_OK);
    return p;
}

} // namespace

TEST_SUITE("coordinator contract") {

// GeometryExecutor reports 0 for the axis that landed; Coordinator forwards it as is.
TEST_CASE("min-size reports merge per axis: 0 keeps the other axis") {
    Engine e;
    reconcile_ok(e, snap(SA, {{2}, {1}}));
    REQUIRE(e.report_min_size(1, 900, 0) == HM_OK);
    REQUIRE(e.report_min_size(1, 0, 500) == HM_OK);
    CHECK(e.min_size(1).w == 900);
    CHECK(e.min_size(1).h == 500);
    CHECK(frame(relayout_ok(e, SA), 1).w == doctest::Approx(900));
    REQUIRE(e.report_min_size(1, 950, 0) == HM_OK);
    CHECK(e.min_size(1).w == 950);
    CHECK(e.min_size(1).h == 500);
}

TEST_CASE("snapshot min-size hints merge per axis too") {
    Engine e;
    reconcile_ok(e, snap(SA, {{2, St::Tiled, 1000, 0}, {1}}));
    reconcile_ok(e, snap(SA, {{2, St::Tiled, 0, 300}, {1}}));
    CHECK(e.min_size(2).w == 1000);
    CHECK(e.min_size(2).h == 300);
}

// Coordinator relayouts after every minSizeDiscovered; with unsatisfiable minimums
// the executor reports the same size again. The geometry must not drift.
TEST_CASE("repeating an unsatisfiable min-size report yields identical plans") {
    Engine e;
    reconcile_ok(e, snap(SA, {{2}, {1}}));
    REQUIRE(e.report_min_size(1, 900, 0) == HM_OK);
    REQUIRE(e.report_min_size(2, 700, 0) == HM_OK);
    const Plan first = relayout_ok(e, SA);
    CHECK(frame(first, 1).w == doctest::Approx(792)); // proportional shortfall
    for (int i = 0; i < 3; ++i) {
        REQUIRE(e.report_min_size(1, 900, 0) == HM_OK);
        const Plan again = relayout_ok(e, SA);
        CHECK(again.revision > first.revision);
        check_same(first, again);
    }
}

// Coordinator.swift re-adds unresolved windows with their last state, frame .zero and
// minSize .zero, appended after the resolved ones.
TEST_CASE("unresolved re-add: zero frame and zero min keep tile and min hint") {
    Engine e;
    reconcile_ok(e, snap(SA, {{3}, {2}, {1}}));
    reconcile_ok(e, snap(SA, {{3}, {2, St::Tiled, 0, 500}, {1}}));
    const Plan before = relayout_ok(e, SA);
    Snapshot s = snap(SA, {{2}, {1}, {3}}); // 3 unresolved -> back of the list
    s.windows[0].frame = {5, 5, 300, 300};
    const Plan p = reconcile_ok(e, s);
    check_same(before, p);
    CHECK(e.min_size(2).h == 500);
}

TEST_CASE("unresolved re-add of a ghost with its last ghost state keeps the ghost") {
    Engine e;
    const Plan full = reconcile_ok(e, snap(SA, {{2}, {1}}));
    reconcile_ok(e, snap(SA, {{1}, {2, St::Minimized}}));
    reconcile_ok(e, snap(SA, {{1}, {2, St::Minimized}})); // re-added from lastStates
    CHECK(e.space_of(2) == SA);
    CHECK(e.model().ghost(2) != nullptr);
    check_same(full, reconcile_ok(e, snap(SA, {{2}, {1}})));
}

// Coordinator.swift skips `.inferred` windows whose engine owner is another Space.
TEST_CASE("space_of reports a ghost's owner, and a foreign ghost-state entry is harmless") {
    Engine e;
    const Plan full = reconcile_ok(e, snap(SA, {{2}, {1}}));
    reconcile_ok(e, snap(SA, {{1}, {2, St::Hidden}}));
    CHECK(e.space_of(2) == SA); // the skip predicate sees the owner
    // Even if the skip were missing, a ghost-state entry elsewhere changes nothing.
    const Plan other = reconcile_ok(e, snap(SB, {{9}, {2, St::Hidden}}, 0, kLeft, 2));
    CHECK_FALSE(has(other, 2));
    CHECK(e.model().ghost(2)->space == SA);
    check_same(full, reconcile_ok(e, snap(SA, {{2}, {1}})));
}

TEST_CASE("a TILED entry for a foreign ghost would steal it (why the skip matters)") {
    Engine e;
    reconcile_ok(e, snap(SA, {{2}, {1}}));
    reconcile_ok(e, snap(SA, {{1}, {2, St::Minimized}}));
    reconcile_ok(e, snap(SB, {{2}}, 0, kLeft, 2));
    CHECK(e.space_of(2) == SB);
    CHECK(e.model().ghost(2) == nullptr);
}

// Fullscreen as discovery reports it: confirmed FULLSCREEN on the fullscreen Space,
// then `.inferred` FULLSCREEN in the owner's snapshot while the user is back on SA.
TEST_CASE("fullscreen round trip through discovery's membership rules") {
    Engine e;
    const Plan full = reconcile_ok(e, snap(SA, {{2}, {1}}));
    constexpr SpaceId kFs = 77;
    reconcile_ok(e, snap(kFs, {{2, St::Fullscreen}}, 2));
    CHECK(e.model().ghost(2)->space == SA);
    const Plan back = reconcile_ok(e, snap(SA, {{1}, {2, St::Fullscreen}}));
    CHECK(back.placements.size() == 1);
    CHECK(e.model().ghost(2) != nullptr);
    e.forget_space(kFs);
    check_same(full, reconcile_ok(e, snap(SA, {{2}, {1}}, 2)));
}

// Coordinator relayouts `engine.space(of:)` after a min-size report; that can be a ghost's Space.
TEST_CASE("relayout after a min report for a ghosted window") {
    Engine e;
    reconcile_ok(e, snap(SA, {{2}, {1}}));
    reconcile_ok(e, snap(SA, {{1}, {2, St::Minimized}}));
    REQUIRE(e.report_min_size(2, 1000, 0) == HM_OK);
    const Plan p = relayout_ok(e, e.space_of(2));
    CHECK(p.placements.size() == 1);
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
    const Plan restored = reconcile_ok(e, snap(SA, {{2}, {1}}));
    CHECK(frame(restored, 2).w == doctest::Approx(1000));
}

// reconcileNow walks displays in provider order; a window that moved from display 1 to
// display 2 must end up in the same state whichever display is reconciled first.
TEST_CASE("window moved between displays: same result in either reconcile order") {
    for (bool dest_first : {false, true}) {
        CAPTURE(dest_first);
        Engine e;
        reconcile_ok(e, snap(SA, {{2}, {1}}));
        reconcile_ok(e, snap(SB, {{5}}, 0, kLeft, 2));
        const Snapshot a = snap(SA, {{1}});
        const Snapshot b = snap(SB, {{2}, {5}}, 2, kLeft, 2);
        Plan pa, pb;
        if (dest_first) {
            pb = reconcile_ok(e, b);
            pa = reconcile_ok(e, a);
        } else {
            pa = reconcile_ok(e, a);
            pb = reconcile_ok(e, b);
        }
        CHECK_RECT(frame(pa, 1), 12, 12, 1416, 876);
        CHECK_RECT(frame(pb, 5), -1908, 12, 944, 1056);
        CHECK_RECT(frame(pb, 2), -956, 12, 944, 1056);
        CHECK(e.space_of(2) == SB);
        CHECK(e.model().ghost_count() == 0);
    }
}

// With "Displays have separate Spaces" off, both displays report the SAME Space id.
// Trees are keyed by Space only, so the two snapshots fight: the coordinator must give
// each display its own (synthetic) hm_space_id in that mode.
TEST_CASE("one Space id shared by two displays: the last snapshot wins") {
    Engine e;
    reconcile_ok(e, snap(SA, {{1}}));
    const Plan p = reconcile_ok(e, snap(SA, {{2}}, 0, kLeft, 2));
    CHECK(p.placements.size() == 1);
    CHECK(e.space_of(1) == 0); // display 1's window was dropped from the tree
}

// reloadConfig only schedules a reconcile (no explicit relayout).
TEST_CASE("a reconcile alone applies a new config") {
    Engine e;
    reconcile_ok(e, snap(SA, {{2}, {1}}));
    REQUIRE(e.set_config({0, 0, 0.5}) == HM_OK);
    const Plan p = reconcile_ok(e, snap(SA, {{2}, {1}}));
    CHECK_RECT(frame(p, 1), 0, 0, 720, 900);
}

// appTerminated -> engine.forget(window:) for every id of the pid, ghosts included.
TEST_CASE("forgetting every window of a terminated app clears ghosts and tiles") {
    Engine e;
    reconcile_ok(e, snap(SA, {{3}, {2}, {1}}));
    reconcile_ok(e, snap(SA, {{1}, {2, St::Hidden}, {3, St::Hidden}}));
    e.forget_window(2);
    e.forget_window(3);
    CHECK(e.model().ghost_count() == 0);
    CHECK(e.space_of(2) == 0);
    const Plan p = reconcile_ok(e, snap(SA, {{1}}));
    CHECK_RECT(frame(p, 1), 12, 12, 1416, 876);
}

} // TEST_SUITE
