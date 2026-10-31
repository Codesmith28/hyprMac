#pragma once
// Shared geometry helpers for the core tests.
#include "doctest.h"
#include "hypr/geometry.hpp"

#include <limits>
#include <ostream>

namespace hypr {
inline std::ostream &operator<<(std::ostream &os, const Rect &r) { return os << "{" << to_string(r) << "}"; }
} // namespace hypr

#define CHECK_RECT(actual, ...)                                                                                    \
    do {                                                                                                           \
        const ::hypr::Rect check_rect_a_ = (actual);                                                               \
        const ::hypr::Rect check_rect_e_ = ::hypr::Rect{__VA_ARGS__};                                              \
        CHECK_MESSAGE(::hypr::nearly_equal(check_rect_a_, check_rect_e_), check_rect_a_ << " != " << check_rect_e_);    \
    } while (0)
