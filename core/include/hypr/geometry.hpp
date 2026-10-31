#pragma once
// Plain geometry used by the layout engine. Top-left origin, x grows right,
// y grows down (same convention as the Accessibility API and hypr_core.h).
#include "hypr/hypr_core.h"

#include <string>

namespace hypr {

// Comparison tolerance for nearly_equal (scaled by magnitude above 1.0).
inline constexpr double kEpsilon = 1e-9;

// Inputs whose magnitude exceeds this are rejected as invalid: no real display
// is a billion points wide, and the bound guarantees that sums of coordinates
// can never overflow to infinity.
inline constexpr double kMaxCoordinate = 1e9;

struct Rect {
    double x = 0, y = 0, w = 0, h = 0;

    double right() const { return x + w; }
    double bottom() const { return y + h; }
    double area() const { return w * h; }

    static Rect from_c(const hm_rect &r) { return {r.x, r.y, r.w, r.h}; }
    hm_rect to_c() const { return {x, y, w, h}; }

    friend bool operator==(const Rect &, const Rect &) = default;
};

// |a - b| <= eps * max(1, |a|, |b|): absolute near zero, relative for large values.
bool nearly_equal(double a, double b, double eps = kEpsilon);
bool nearly_equal(const Rect &a, const Rect &b, double eps = kEpsilon);

// A finite number whose magnitude is at most kMaxCoordinate.
bool is_valid_scalar(double v);
// Every component passes is_valid_scalar. Width/height may be <= 0.
bool is_valid_rect(const Rect &r);

// Shrink by d on every side (may produce non-positive sizes).
Rect inset(const Rect &r, double d);

// Area of the overlap of a and b (0 when disjoint or touching).
double intersection_area(const Rect &a, const Rect &b);

// inner lies within outer, allowing a slack of eps on each edge.
bool contains(const Rect &outer, const Rect &inner, double eps = 1e-6);

// "x,y,w,h" using %.10g per component (stable, used by debug dumps).
std::string to_string(const Rect &r);

} // namespace hypr
