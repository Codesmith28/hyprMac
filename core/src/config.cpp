#include "hypr/config.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace hypr {

std::string validate(const Config &c) {
    auto check_gap = [](const char *name, double v) -> std::string {
        if (!std::isfinite(v)) return std::string(name) + " must be a finite number";
        if (v < 0.0) return std::string(name) + " must be >= 0";
        if (v > kMaxGap) return std::string(name) + " must be <= 200";
        return {};
    };
    if (auto e = check_gap("gaps.inner", c.inner_gap); !e.empty()) return e;
    if (auto e = check_gap("gaps.outer", c.outer_gap); !e.empty()) return e;
    if (!std::isfinite(c.split_ratio) || c.split_ratio < kMinRatio || c.split_ratio > kMaxRatio)
        return "split_ratio must be within [0.1, 0.9]";
    auto check_float = [](const char *name, double v) -> std::string {
        if (!std::isfinite(v)) return std::string(name) + " must be a finite number";
        if (v < 0.0 || v > kMaxFloatMin) return std::string(name) + " must be within [0, 2000]";
        return {};
    };
    if (auto e = check_float("float.min_width", c.float_min_w); !e.empty()) return e;
    if (auto e = check_float("float.min_height", c.float_min_h); !e.empty()) return e;
    return {};
}

} // namespace hypr

extern "C" void hm_config_default(hm_config *out) {
    if (out) *out = hypr::Config{}.to_c();
}

extern "C" hm_status hm_config_validate(const hm_config *cfg, char *err, size_t err_cap) {
    if (!cfg) {
        if (err && err_cap) std::snprintf(err, err_cap, "null config");
        return HM_ERR_INVALID_ARGUMENT;
    }
    std::string e = hypr::validate(hypr::Config::from_c(*cfg));
    if (e.empty()) return HM_OK;
    if (err && err_cap) std::snprintf(err, err_cap, "%s", e.c_str());
    return HM_ERR_CONFIG;
}
