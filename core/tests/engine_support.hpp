#pragma once
// Engine-level helpers for the core tests.
#include "layout_support.hpp"

#include "hypr/engine.hpp"

#include <initializer_list>
#include <string>

namespace hypr::test {

inline constexpr Rect kUsable{0, 0, 1440, 900};

using St = WindowState;

struct W {
    WindowId id;
    St state = St::Tiled;
    double min_w = 0, min_h = 0;
};

inline Snapshot snap(SpaceId space, std::initializer_list<W> windows, WindowId focused = 0,
                     Rect usable = kUsable, DisplayId display = 1) {
    Snapshot s;
    s.display = display;
    s.space = space;
    s.usable = usable;
    s.focused = focused;
    for (const W &w : windows) s.windows.push_back({w.id, w.state, {}, w.min_w, w.min_h});
    return s;
}

inline Plan reconcile_ok(Engine &e, const Snapshot &s) {
    Plan p;
    REQUIRE(e.reconcile(s, p) == HM_OK);
    std::string why;
    REQUIRE_MESSAGE(e.model().check_invariants(&why), why);
    return p;
}

inline bool has(const Plan &p, WindowId w) {
    for (const auto &pl : p.placements)
        if (pl.id == w) return true;
    return false;
}

inline Rect frame(const Plan &p, WindowId w) {
    for (const auto &pl : p.placements)
        if (pl.id == w) return pl.frame;
    FAIL("window " << w << " not in plan");
    return {};
}

} // namespace hypr::test
