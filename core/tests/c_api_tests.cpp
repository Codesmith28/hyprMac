#include "test_support.hpp"

#include "hypr/engine.hpp"
#include "hypr/hypr_core.h"

#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

struct EngineGuard {
    hm_engine *e;
    explicit EngineGuard(const hm_config *cfg = nullptr) : e(hm_engine_create(cfg)) { REQUIRE(e != nullptr); }
    ~EngineGuard() { hm_engine_destroy(e); }
    EngineGuard(const EngineGuard &) = delete;
    EngineGuard &operator=(const EngineGuard &) = delete;
};

hm_window_info win(hm_window_id id, hm_window_state st = HM_WINDOW_TILED) {
    hm_window_info w{};
    w.id = id;
    w.state = st;
    return w;
}

hm_space_snapshot snap(hm_space_id space, const std::vector<hm_window_info> &ws, hm_window_id focused = 0) {
    hm_space_snapshot s{};
    s.display = 1;
    s.space = space;
    s.usable = {0, 0, 1440, 900};
    s.focused = focused;
    s.windows = ws.empty() ? nullptr : ws.data();
    s.window_count = ws.size();
    return s;
}

std::string dump(const hm_engine *e, hm_space_id space) {
    const size_t n = hm_engine_debug_dump(e, space, nullptr, 0);
    std::string out(n + 1, '\0');
    hm_engine_debug_dump(e, space, out.data(), out.size());
    out.resize(n);
    return out;
}

} // namespace

TEST_SUITE("c_api") {

TEST_CASE("hm_version") { CHECK(std::string(hm_version()) == "0.1.0"); }

TEST_CASE("engine create and destroy") {
    hm_engine *e = hm_engine_create(nullptr);
    REQUIRE(e != nullptr);
    hm_engine_destroy(e);
    hm_engine_destroy(nullptr);
    hm_config bad{-1, 12, 0.5};
    CHECK(hm_engine_create(&bad) == nullptr);
    hm_config nan_cfg{std::numeric_limits<double>::quiet_NaN(), 12, 0.5};
    CHECK(hm_engine_create(&nan_cfg) == nullptr);
    hm_config ok{0, 0, 0.5};
    hm_engine *e2 = hm_engine_create(&ok);
    CHECK(e2 != nullptr);
    hm_engine_destroy(e2);
}

TEST_CASE("blueprint through the C API") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(2), win(1)};
    hm_space_snapshot s = snap(5, ws);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    CHECK(p.space == 5);
    CHECK(p.revision == 1);
    REQUIRE(p.count == 2);
    // Back to front: 1 is inserted first (left), 2 second (right).
    CHECK(p.placements[0].id == 1);
    CHECK(p.placements[0].frame.x == 12);
    CHECK(p.placements[0].frame.w == 704);
    CHECK(p.placements[1].id == 2);
    CHECK(p.placements[1].frame.x == 724);
    CHECK(p.placements[1].frame.h == 876);
    CHECK(hm_engine_tiled_count(g.e, 5) == 2);
    CHECK(hm_engine_space_of(g.e, 2) == 5);
    hm_plan_free(&p);
}

TEST_CASE("hm_plan_free is idempotent") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(1)};
    hm_space_snapshot s = snap(5, ws);
    const long before = hypr::diag::live_plan_buffers();
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    CHECK(hypr::diag::live_plan_buffers() == before + 1);
    hm_plan_free(&p);
    CHECK(p.placements == nullptr);
    CHECK(p.count == 0);
    hm_plan_free(&p);
    hm_plan_free(nullptr);
    hm_plan zero{};
    hm_plan_free(&zero);
    CHECK(hypr::diag::live_plan_buffers() == before);
}

TEST_CASE("empty plans carry no buffer") {
    EngineGuard g;
    hm_space_snapshot s = snap(5, {});
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    CHECK(p.count == 0);
    CHECK(p.placements == nullptr);
    hm_plan_free(&p);
}

TEST_CASE("null pointers are rejected everywhere") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(1)};
    hm_space_snapshot s = snap(5, ws);
    hm_plan p{};
    hm_config c{};
    hm_config_default(&c);
    CHECK(hm_engine_reconcile(nullptr, &s, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_reconcile(g.e, nullptr, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_reconcile(g.e, &s, nullptr) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_relayout(nullptr, 5, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_relayout(g.e, 5, nullptr) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_swap(nullptr, 1, 2, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_swap(g.e, 1, 2, nullptr) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_set_config(nullptr, &c) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_set_config(g.e, nullptr) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_report_min_size(nullptr, 1, 1, 1) == HM_ERR_INVALID_ARGUMENT);
    hm_engine_forget_window(nullptr, 1);
    hm_engine_forget_space(nullptr, 1);
    CHECK(hm_engine_space_of(nullptr, 1) == 0);
    CHECK(hm_engine_tiled_count(nullptr, 5) == 0);
    char buf[8] = "xxxxxxx";
    CHECK(hm_engine_debug_dump(nullptr, 5, buf, sizeof buf) == 0);
    CHECK(buf[0] == '\0');
    CHECK(p.count == 0);
    CHECK(p.placements == nullptr);
}

TEST_CASE("windows == NULL is only valid with a zero count") {
    EngineGuard g;
    hm_space_snapshot s = snap(5, {});
    s.window_count = 3;
    hm_plan p{};
    CHECK(hm_engine_reconcile(g.e, &s, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_tiled_count(g.e, 5) == 0);
}

TEST_CASE("hostile snapshots are rejected and change nothing") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(2), win(1)};
    hm_space_snapshot good = snap(5, ws);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &good, &p) == HM_OK);
    hm_plan_free(&p);
    const std::string before = dump(g.e, 5);
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();

    auto expect_rejected = [&](hm_space_snapshot s) {
        hm_plan out{};
        CHECK(hm_engine_reconcile(g.e, &s, &out) == HM_ERR_INVALID_ARGUMENT);
        CHECK(out.placements == nullptr);
        CHECK(dump(g.e, 5) == before);
        CHECK(hm_engine_space_of(g.e, 3) == 0);
    };

    std::vector<hm_window_info> zero_id{win(3), win(0)};
    expect_rejected(snap(5, zero_id));

    std::vector<hm_window_info> three{win(3), win(2), win(1)};
    hm_space_snapshot s = snap(5, three);
    s.usable.w = nan;
    expect_rejected(s);
    s = snap(5, three);
    s.usable.y = -inf;
    expect_rejected(s);
    s = snap(0, three);
    expect_rejected(s);

    std::vector<hm_window_info> frame_nan = three;
    frame_nan[2].frame.x = nan;
    expect_rejected(snap(5, frame_nan));

    std::vector<hm_window_info> min_inf = three;
    min_inf[0].min_h = inf;
    expect_rejected(snap(5, min_inf));

    // A state value outside the enum, written as raw bytes like a foreign caller could.
    std::vector<hm_window_info> bad_state = three;
    const std::underlying_type_t<hm_window_state> raw = 42;
    std::memcpy(&bad_state[0].state, &raw, sizeof raw);
    expect_rejected(snap(5, bad_state));

    // Window id 0 everywhere else.
    CHECK(hm_engine_report_min_size(g.e, 0, 1, 1) == HM_ERR_INVALID_ARGUMENT);
    hm_plan out{};
    CHECK(hm_engine_swap(g.e, 0, 1, &out) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_space_of(g.e, 0) == 0);
    hm_engine_forget_window(g.e, 0);
    CHECK(dump(g.e, 5) == before);
}

TEST_CASE("duplicate ids through the C API: first occurrence wins") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(1, HM_WINDOW_FLOATING), win(1), win(2)};
    hm_space_snapshot s = snap(5, ws);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    REQUIRE(p.count == 1);
    CHECK(p.placements[0].id == 2);
    hm_plan_free(&p);
}

TEST_CASE("relayout, swap and min size through the C API") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(2), win(1)};
    hm_space_snapshot s = snap(5, ws);
    std::vector<hm_window_info> other{win(9)};
    hm_space_snapshot s2 = snap(6, other);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    hm_plan_free(&p);
    REQUIRE(hm_engine_reconcile(g.e, &s2, &p) == HM_OK);
    hm_plan_free(&p);

    CHECK(hm_engine_relayout(g.e, 77, &p) == HM_ERR_UNKNOWN_SPACE);
    CHECK(hm_engine_swap(g.e, 1, 9, &p) == HM_ERR_INVALID_ARGUMENT);
    CHECK(hm_engine_swap(g.e, 1, 404, &p) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_report_min_size(g.e, 404, 1, 1) == HM_ERR_UNKNOWN_WINDOW);
    CHECK(hm_engine_report_min_size(g.e, 1, std::numeric_limits<double>::quiet_NaN(), 1) ==
          HM_ERR_INVALID_ARGUMENT);

    REQUIRE(hm_engine_report_min_size(g.e, 1, 900, 0) == HM_OK);
    REQUIRE(hm_engine_relayout(g.e, 5, &p) == HM_OK);
    CHECK(p.revision == 3);
    REQUIRE(p.count == 2);
    CHECK(p.placements[0].frame.w == 900);
    hm_plan_free(&p);

    REQUIRE(hm_engine_swap(g.e, 1, 2, &p) == HM_OK);
    CHECK(p.revision == 4);
    CHECK(p.placements[0].id == 2);
    hm_plan_free(&p);
}

TEST_CASE("set_config through the C API") {
    EngineGuard g;
    hm_config bad{0, 0, 2.0};
    CHECK(hm_engine_set_config(g.e, &bad) == HM_ERR_CONFIG);
    hm_config zero{0, 0, 0.5};
    REQUIRE(hm_engine_set_config(g.e, &zero) == HM_OK);
    std::vector<hm_window_info> ws{win(1)};
    hm_space_snapshot s = snap(5, ws);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    CHECK(p.placements[0].frame.w == 1440);
    hm_plan_free(&p);
}

TEST_CASE("forget_window, forget_space and space_of through the C API") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(3, HM_WINDOW_MINIMIZED), win(2), win(1)};
    std::vector<hm_window_info> first{win(3), win(2), win(1)};
    hm_space_snapshot s = snap(5, first);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    hm_plan_free(&p);
    s = snap(5, ws);
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    hm_plan_free(&p);
    CHECK(hm_engine_space_of(g.e, 3) == 5); // ghost slot
    CHECK(hm_engine_tiled_count(g.e, 5) == 2);
    hm_engine_forget_window(g.e, 3);
    CHECK(hm_engine_space_of(g.e, 3) == 0);
    hm_engine_forget_space(g.e, 5);
    CHECK(hm_engine_space_of(g.e, 1) == 0);
    CHECK(hm_engine_tiled_count(g.e, 5) == 0);
    CHECK(hm_engine_tiled_count(g.e, 12345) == 0);
}

TEST_CASE("debug_dump follows snprintf semantics") {
    EngineGuard g;
    std::vector<hm_window_info> ws{win(1)};
    hm_space_snapshot s = snap(5, ws);
    hm_plan p{};
    REQUIRE(hm_engine_reconcile(g.e, &s, &p) == HM_OK);
    hm_plan_free(&p);
    const std::string full = "space 5 display 1 usable 0,0,1440,900 leaves 1\nwin 0x1 12,12,1416,876\n";
    CHECK(hm_engine_debug_dump(g.e, 5, nullptr, 0) == full.size());
    char small[10];
    CHECK(hm_engine_debug_dump(g.e, 5, small, sizeof small) == full.size());
    CHECK(std::string(small) == full.substr(0, 9));
    std::vector<char> big(full.size() + 1);
    CHECK(hm_engine_debug_dump(g.e, 5, big.data(), big.size()) == full.size());
    CHECK(std::string(big.data()) == full);
    char one[1] = {'x'};
    CHECK(hm_engine_debug_dump(g.e, 5, one, 1) == full.size());
    CHECK(one[0] == '\0');
    char unknown[4] = "abc";
    CHECK(hm_engine_debug_dump(g.e, 99, unknown, sizeof unknown) == 0);
    CHECK(unknown[0] == '\0');
}

} // TEST_SUITE
