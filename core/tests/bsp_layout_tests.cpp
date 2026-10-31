#include "layout_support.hpp"

#include "hypr/bsp_layout.hpp"

#include <unordered_map>

using namespace hypr;
using hypr::test::expected_gap_area;
using hypr::test::frame;
using hypr::test::layout_problem;

namespace {

const Rect kScreen{0, 0, 1440, 900};

LayoutTree pair(Orientation o = Orientation::Vertical, double ratio = 0.5) {
    LayoutTree t;
    t.insert_root(1);
    t.insert(1, 2, o, ratio);
    return t;
}

// Build n windows the way the engine does without focus: each new window splits
// the most recently inserted leaf along its longer side.
LayoutTree dwindle(int n, const Rect &usable, const Config &cfg) {
    LayoutTree t;
    t.insert_root(1);
    for (WindowId w = 2; w <= static_cast<WindowId>(n); ++w) {
        const LayoutResult l = compute_layout(t, usable, cfg);
        t.insert(w - 1, w, dwindle_orientation(frame(l, w - 1)), cfg.split_ratio);
    }
    return t;
}

MinSizeLookup mins(std::unordered_map<WindowId, MinSize> m) {
    return [m = std::move(m)](WindowId w) {
        auto it = m.find(w);
        return it == m.end() ? MinSize{} : it->second;
    };
}

} // namespace

TEST_SUITE("bsp_layout") {

TEST_CASE("blueprint: 1440x900, outer 12, inner 8") {
    const LayoutResult l = compute_layout(pair(), kScreen, Config{});
    CHECK_RECT(l.root, 12, 12, 1416, 876);
    REQUIRE(l.placements.size() == 2);
    CHECK(l.placements[0].id == 1);
    CHECK_RECT(frame(l, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(l, 2), 724, 12, 704, 876);
    CHECK_FALSE(l.degenerate);
    CHECK(l.gap_area == doctest::Approx(8 * 876));
}

TEST_CASE("a single window gets exactly R") {
    LayoutTree t;
    t.insert_root(1);
    const LayoutResult l = compute_layout(t, kScreen, Config{});
    CHECK_RECT(frame(l, 1), 12, 12, 1416, 876);
    CHECK(l.gap_area == 0);
}

TEST_CASE("an empty tree has no placements") {
    const LayoutResult l = compute_layout(LayoutTree{}, kScreen, Config{});
    CHECK(l.placements.empty());
    CHECK_RECT(l.root, 12, 12, 1416, 876);
}

TEST_CASE("nested gaps are local to each split") {
    LayoutTree t = pair();
    t.insert(2, 3, Orientation::Horizontal, 0.5);
    const LayoutResult l = compute_layout(t, kScreen, Config{});
    CHECK_RECT(frame(l, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(l, 2), 724, 12, 704, 434);
    CHECK_RECT(frame(l, 3), 724, 454, 704, 434);
    CHECK(frame(l, 3).y - frame(l, 2).bottom() == doctest::Approx(8));
    CHECK(frame(l, 2).x - frame(l, 1).right() == doctest::Approx(8));
    CHECK(layout_problem(l, kScreen, 12) == "");
}

TEST_CASE("zero gaps tile edge to edge") {
    const LayoutResult l = compute_layout(pair(), kScreen, Config{0, 0, 0.5});
    CHECK_RECT(frame(l, 1), 0, 0, 720, 900);
    CHECK_RECT(frame(l, 2), 720, 0, 720, 900);
    CHECK(l.gap_area == 0);
}

TEST_CASE("split ratio goes to the first child") {
    const LayoutResult l = compute_layout(pair(Orientation::Vertical, 0.3), kScreen, Config{});
    CHECK_RECT(frame(l, 1), 12, 12, 422.4, 876);
    CHECK_RECT(frame(l, 2), 442.4, 12, 985.6, 876);
}

TEST_CASE("5 and 8 windows: area identity, no overlap, inside R") {
    for (int n : {5, 8}) {
        CAPTURE(n);
        const LayoutTree t = dwindle(n, kScreen, Config{});
        const LayoutResult l = compute_layout(t, kScreen, Config{});
        CHECK(l.placements.size() == static_cast<std::size_t>(n));
        CHECK_FALSE(l.degenerate);
        CHECK(layout_problem(l, kScreen, 12) == "");
        CHECK(l.gap_area == doctest::Approx(expected_gap_area(t.root(), l, 8)));
    }
    const LayoutResult l5 = compute_layout(dwindle(5, kScreen, Config{}), kScreen, Config{});
    CHECK_RECT(frame(l5, 4), 1080, 454, 348, 213);
    CHECK_RECT(frame(l5, 5), 1080, 675, 348, 213);
}

TEST_CASE("200 pt gaps on a small screen shrink the gap instead of going negative") {
    const Config cfg{200, 200, 0.5};
    const Rect usable{0, 0, 600, 500};
    const LayoutResult l = compute_layout(pair(), usable, cfg);
    CHECK_RECT(l.root, 200, 200, 200, 100);
    CHECK(l.degenerate);
    CHECK_RECT(frame(l, 1), 200, 200, 1, 100);
    CHECK_RECT(frame(l, 2), 399, 200, 1, 100);
    CHECK(layout_problem(l, usable, 200) == "");
}

TEST_CASE("outer gap larger than the screen clamps R to 1x1 without NaN") {
    const Config cfg{200, 200, 0.5};
    const Rect usable{0, 0, 300, 200};
    LayoutTree t = pair();
    t.insert(2, 3, Orientation::Horizontal, 0.5);
    const LayoutResult l = compute_layout(t, usable, cfg);
    CHECK(l.degenerate);
    CHECK_RECT(l.root, 149.5, 99.5, 1, 1);
    for (const auto &p : l.placements) {
        CHECK(is_valid_rect(p.frame));
        CHECK(p.frame.w >= 1);
        CHECK(p.frame.h >= 1);
    }
    LayoutTree single;
    single.insert_root(1);
    CHECK_RECT(frame(compute_layout(single, {0, 0, -50, 0}, cfg), 1), -25.5, -0.5, 1, 1);
}

TEST_CASE("second display at a negative x origin") {
    const Rect usable{-1920, 25, 1920, 1055};
    const LayoutResult l = compute_layout(pair(), usable, Config{});
    CHECK_RECT(frame(l, 1), -1908, 37, 944, 1031);
    CHECK_RECT(frame(l, 2), -956, 37, 944, 1031);
    CHECK(layout_problem(l, usable, 12) == "");
}

TEST_CASE("display above the primary (negative y)") {
    const Rect usable{0, -1080, 1920, 1080};
    const LayoutResult l = compute_layout(pair(), usable, Config{});
    CHECK_RECT(frame(l, 1), 12, -1068, 944, 1056);
    CHECK_RECT(frame(l, 2), 964, -1068, 944, 1056);
}

TEST_CASE("dwindle orientation follows the longer side, ties are vertical") {
    CHECK(dwindle_orientation({0, 0, 10, 5}) == Orientation::Vertical);
    CHECK(dwindle_orientation({0, 0, 5, 10}) == Orientation::Horizontal);
    CHECK(dwindle_orientation({0, 0, 10, 10}) == Orientation::Vertical);
    CHECK(dwindle_orientation({-100, -100, 704, 876}) == Orientation::Horizontal);
}

TEST_CASE("min size on the first child shifts the split") {
    LayoutTree t = pair();
    const LayoutResult l = compute_layout(t, kScreen, Config{}, mins({{1, {900, 0}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 900, 876);
    CHECK_RECT(frame(l, 2), 920, 12, 508, 876);
    CHECK(t.root()->ratio == 0.5); // stored ratio untouched
    CHECK_FALSE(l.degenerate);
}

TEST_CASE("min size on the second child shifts the split") {
    const LayoutResult l = compute_layout(pair(), kScreen, Config{}, mins({{2, {1000, 0}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 408, 876);
    CHECK_RECT(frame(l, 2), 428, 12, 1000, 876);
}

TEST_CASE("min height on a horizontal split") {
    const LayoutResult l = compute_layout(pair(Orientation::Horizontal), kScreen, Config{}, mins({{1, {0, 600}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 1416, 600);
    CHECK_RECT(frame(l, 2), 12, 620, 1416, 268);
}

TEST_CASE("unsatisfiable minimums divide in proportion") {
    const LayoutResult l = compute_layout(pair(), kScreen, Config{}, mins({{1, {900, 0}}, {2, {700, 0}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 792, 876);
    CHECK_RECT(frame(l, 2), 812, 12, 616, 876);
    CHECK(layout_problem(l, kScreen, 12) == "");

    // A minimum across the split axis larger than the screen: accept the shortfall.
    const LayoutResult tall = compute_layout(pair(), kScreen, Config{}, mins({{1, {0, 5000}}}));
    CHECK_RECT(frame(tall, 1), 12, 12, 704, 876);

    // One huge minimum leaves the other tile at its 1 pt floor, still inside R.
    const LayoutResult huge = compute_layout(pair(), kScreen, Config{}, mins({{1, {1500, 0}}}));
    CHECK(frame(huge, 2).w == doctest::Approx(1));
    CHECK(layout_problem(huge, kScreen, 12) == "");
}

TEST_CASE("nested minimums along the same axis include the inner gap") {
    LayoutTree t;
    t.insert_root(1);
    t.insert(1, 2, Orientation::Vertical, 0.5);
    t.insert(2, 3, Orientation::Vertical, 0.5); // A | (B | C)
    const LayoutResult l = compute_layout(t, kScreen, Config{}, mins({{2, {400, 0}}, {3, {400, 0}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 600, 876);
    CHECK_RECT(frame(l, 2), 620, 12, 400, 876);
    CHECK_RECT(frame(l, 3), 1028, 12, 400, 876);
}

TEST_CASE("nested minimums across the axis use the max") {
    LayoutTree t = pair();
    t.insert(2, 3, Orientation::Horizontal, 0.5); // A | (B / C)
    const LayoutResult l = compute_layout(t, kScreen, Config{}, mins({{3, {900, 0}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 508, 876);
    CHECK_RECT(frame(l, 2), 528, 12, 900, 434);
    CHECK_RECT(frame(l, 3), 528, 454, 900, 434);
}

TEST_CASE("garbage minimums from the lookup are ignored") {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const LayoutResult l = compute_layout(pair(), kScreen, Config{}, mins({{1, {nan, -5}}, {2, {-100, nan}}}));
    CHECK_RECT(frame(l, 1), 12, 12, 704, 876);
    CHECK_RECT(frame(l, 2), 724, 12, 704, 876);
}

} // TEST_SUITE
