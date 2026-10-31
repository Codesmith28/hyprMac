#include "hypr/geometry.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace hypr {

bool nearly_equal(double a, double b, double eps) {
    const double scale = std::max({1.0, std::fabs(a), std::fabs(b)});
    return std::fabs(a - b) <= eps * scale;
}

bool nearly_equal(const Rect &a, const Rect &b, double eps) {
    return nearly_equal(a.x, b.x, eps) && nearly_equal(a.y, b.y, eps) && nearly_equal(a.w, b.w, eps) &&
           nearly_equal(a.h, b.h, eps);
}

bool is_valid_scalar(double v) { return std::isfinite(v) && std::fabs(v) <= kMaxCoordinate; }

bool is_valid_rect(const Rect &r) {
    return is_valid_scalar(r.x) && is_valid_scalar(r.y) && is_valid_scalar(r.w) && is_valid_scalar(r.h);
}

Rect inset(const Rect &r, double d) { return {r.x + d, r.y + d, r.w - 2 * d, r.h - 2 * d}; }

double intersection_area(const Rect &a, const Rect &b) {
    const double w = std::min(a.right(), b.right()) - std::max(a.x, b.x);
    const double h = std::min(a.bottom(), b.bottom()) - std::max(a.y, b.y);
    if (w <= 0 || h <= 0) return 0.0;
    return w * h;
}

bool contains(const Rect &outer, const Rect &inner, double eps) {
    return inner.x >= outer.x - eps && inner.y >= outer.y - eps && inner.right() <= outer.right() + eps &&
           inner.bottom() <= outer.bottom() + eps;
}

std::string to_string(const Rect &r) {
    char buf[128];
    std::snprintf(buf, sizeof buf, "%.10g,%.10g,%.10g,%.10g", r.x, r.y, r.w, r.h);
    return buf;
}

} // namespace hypr
