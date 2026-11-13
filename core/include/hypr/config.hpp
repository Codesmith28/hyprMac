#pragma once
// C++ view of the configuration. Shared by the engine (Agent A) and the Lua loader (Agent B).
#include "hypr/hypr_core.h"
#include <string>

namespace hypr {

inline constexpr double kMaxGap = 200.0;
inline constexpr double kMinRatio = 0.1;
inline constexpr double kMaxRatio = 0.9;
inline constexpr double kMaxFloatMin = 2000.0;
inline constexpr double kMinResizeStep = 1.0;
inline constexpr double kMaxResizeStep = 25.0;

struct Config {
    double inner_gap = 8.0;
    double outer_gap = 12.0;
    double split_ratio = 0.5;
    double float_min_w = 400.0;
    double float_min_h = 300.0;
    double resize_step = 5.0;

    static Config from_c(const hm_config &c) {
        return {c.inner_gap, c.outer_gap, c.split_ratio, c.float_min_w, c.float_min_h, c.resize_step};
    }
    hm_config to_c() const { return {inner_gap, outer_gap, split_ratio, float_min_w, float_min_h, resize_step}; }
};

// Returns empty string when valid, otherwise a human readable reason.
std::string validate(const Config &cfg);

} // namespace hypr
