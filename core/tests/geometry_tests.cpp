#include "test_support.hpp"

#include "hypr/geometry.hpp"

#include <limits>

using hypr::Rect;

TEST_SUITE("geometry") {

TEST_CASE("nearly_equal uses a 1e-9 epsilon") {
    CHECK(hypr::kEpsilon == 1e-9);
    CHECK(hypr::nearly_equal(1.0, 1.0 + 5e-10));
    CHECK_FALSE(hypr::nearly_equal(1.0, 1.0 + 5e-9));
    CHECK(hypr::nearly_equal(0.0, -1e-10));
    CHECK(hypr::nearly_equal(1e6, 1e6 + 1e-4)); // relative above 1.0
    CHECK_FALSE(hypr::nearly_equal(1e6, 1e6 + 1e-2));
    CHECK(hypr::nearly_equal(Rect{1, 2, 3, 4}, Rect{1, 2, 3, 4 + 1e-12}));
    CHECK_FALSE(hypr::nearly_equal(Rect{1, 2, 3, 4}, Rect{1, 2, 3.001, 4}));
}

TEST_CASE("is_valid_rect rejects non-finite and absurd values") {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();
    CHECK(hypr::is_valid_rect({0, 0, 1440, 900}));
    CHECK(hypr::is_valid_rect({-1920, -50, -3, 0})); // negative sizes are finite
    CHECK_FALSE(hypr::is_valid_rect({nan, 0, 1, 1}));
    CHECK_FALSE(hypr::is_valid_rect({0, inf, 1, 1}));
    CHECK_FALSE(hypr::is_valid_rect({0, 0, -inf, 1}));
    CHECK_FALSE(hypr::is_valid_rect({0, 0, 1, 2e9}));
}

TEST_CASE("inset, area and edges") {
    const Rect r = hypr::inset({0, 0, 1440, 900}, 12);
    CHECK(r == Rect{12, 12, 1416, 876});
    CHECK(r.right() == 1428);
    CHECK(r.bottom() == 888);
    CHECK(Rect{0, 0, 3, 4}.area() == 12);
    CHECK(hypr::inset({0, 0, 10, 10}, 6).w == -2);
}

TEST_CASE("intersection_area") {
    CHECK(hypr::intersection_area({0, 0, 10, 10}, {5, 5, 10, 10}) == 25);
    CHECK(hypr::intersection_area({0, 0, 10, 10}, {10, 0, 10, 10}) == 0); // touching
    CHECK(hypr::intersection_area({0, 0, 10, 10}, {20, 20, 1, 1}) == 0);
    CHECK(hypr::intersection_area({0, 0, 10, 10}, {2, 2, 2, 2}) == 4);
}

TEST_CASE("contains allows a small slack") {
    CHECK(hypr::contains({0, 0, 10, 10}, {0, 0, 10, 10}));
    CHECK(hypr::contains({0, 0, 10, 10}, {0, 0, 10 + 1e-9, 10}));
    CHECK_FALSE(hypr::contains({0, 0, 10, 10}, {-1, 0, 5, 5}));
    CHECK_FALSE(hypr::contains({0, 0, 10, 10}, {6, 6, 5, 5}));
}

TEST_CASE("to_string and C conversion round-trip") {
    CHECK(hypr::to_string({12, -1068.5, 704, 876}) == "12,-1068.5,704,876");
    const hm_rect c = Rect{1, 2, 3, 4}.to_c();
    CHECK(Rect::from_c(c) == Rect{1, 2, 3, 4});
}

} // TEST_SUITE
