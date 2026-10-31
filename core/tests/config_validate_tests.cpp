#include "doctest.h"
#include "hypr/config.hpp"
#include <cmath>
#include <limits>

TEST_CASE("defaults are valid") {
    hm_config c;
    hm_config_default(&c);
    CHECK(c.inner_gap == 8.0);
    CHECK(c.outer_gap == 12.0);
    CHECK(c.split_ratio == 0.5);
    CHECK(hm_config_validate(&c, nullptr, 0) == HM_OK);
}

TEST_CASE("validate rejects bad values") {
    hypr::Config c;
    c.inner_gap = -1; CHECK(!hypr::validate(c).empty());
    c = {}; c.outer_gap = std::numeric_limits<double>::quiet_NaN(); CHECK(!hypr::validate(c).empty());
    c = {}; c.outer_gap = std::numeric_limits<double>::infinity(); CHECK(!hypr::validate(c).empty());
    c = {}; c.inner_gap = 201; CHECK(!hypr::validate(c).empty());
    c = {}; c.split_ratio = 0.05; CHECK(!hypr::validate(c).empty());
    c = {}; c.inner_gap = 0; c.outer_gap = 200; CHECK(hypr::validate(c).empty());
    char buf[64];
    hm_config bad{-3, 0, 0.5};
    CHECK(hm_config_validate(&bad, buf, sizeof buf) == HM_ERR_CONFIG);
    CHECK(std::string(buf).find("inner") != std::string::npos);
    CHECK(hm_config_validate(nullptr, buf, sizeof buf) == HM_ERR_INVALID_ARGUMENT);
}
