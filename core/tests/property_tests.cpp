// Randomised model-based tests: a simulated "world" of windows on spaces is
// mutated at random and fed to the engine as snapshots. After every step the
// engine's trees and plans are checked against the world and against the
// geometric invariants of the layout.
#include "engine_support.hpp"

#include "hypr/hypr_core.h"

#include <algorithm>
#include <map>
#include <random>
#include <set>
#include <vector>

using namespace hypr;
using namespace hypr::test;

namespace {

constexpr int kSteps = 10000;
constexpr std::size_t kMaxWindows = 14;

struct WorldWindow {
    SpaceId space = 0;
    WindowState state = WindowState::Tiled;
    double min_w = 0, min_h = 0;
};

class World {
public:
    explicit World(std::uint64_t seed) : rng_(seed) {
        spaces_[1] = {1, {0, 0, 1440, 900}};
        spaces_[2] = {1, {0, 0, 1440, 900}};
        spaces_[3] = {2, {-1920, -200, 1920, 1080}};
    }

    std::mt19937_64 &rng() { return rng_; }
    int uniform(int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng_); }
    double real(double lo, double hi) { return std::uniform_real_distribution<double>(lo, hi)(rng_); }
    bool chance(double p) { return real(0, 1) < p; }

    SpaceId random_space() { return static_cast<SpaceId>(uniform(1, 3)); }

    std::vector<WindowId> windows_on(SpaceId s) const {
        std::vector<WindowId> out;
        for (const auto &[id, w] : windows_)
            if (w.space == s) out.push_back(id);
        return out;
    }

    WindowId random_window() {
        if (windows_.empty()) return next_id_ + 1000; // unknown
        auto it = windows_.begin();
        std::advance(it, uniform(0, static_cast<int>(windows_.size()) - 1));
        return it->first;
    }

    WindowState random_state() {
        const int r = uniform(0, 9);
        if (r < 5) return WindowState::Tiled;
        return static_cast<WindowState>(uniform(1, 4));
    }

    Config random_config() {
        Config c;
        const double max_gap = chance(0.2) ? 200.0 : 40.0;
        c.inner_gap = real(0, max_gap);
        c.outer_gap = real(0, max_gap);
        c.split_ratio = real(0.1, 0.9);
        if (chance(0.1)) c = Config{};
        return c;
    }

    // Mutate the world around space s and return a snapshot of it.
    Snapshot step_snapshot(SpaceId s) {
        const int mutations = uniform(0, 3);
        for (int i = 0; i < mutations; ++i) {
            const auto here = windows_on(s);
            switch (uniform(0, 5)) {
            case 0: // open
                if (windows_.size() < kMaxWindows) windows_[++next_id_] = {s, WindowState::Tiled, 0, 0};
                break;
            case 1: // close
                if (!here.empty()) windows_.erase(here[static_cast<std::size_t>(uniform(0, int(here.size()) - 1))]);
                break;
            case 2: // state change (minimize, hide, float, ...)
            case 3:
                if (!here.empty())
                    windows_[here[static_cast<std::size_t>(uniform(0, int(here.size()) - 1))]].state = random_state();
                break;
            case 4: { // move a window here from anywhere (maybe as a fullscreen window)
                if (windows_.empty()) break;
                WorldWindow &w = windows_[random_window()];
                w.space = s;
                w.state = chance(0.25) ? WindowState::Fullscreen : WindowState::Tiled;
                break;
            }
            case 5: // min size hint
                if (!here.empty()) {
                    WorldWindow &w = windows_[here[static_cast<std::size_t>(uniform(0, int(here.size()) - 1))]];
                    w.min_w = chance(0.5) ? 0 : real(0, 900);
                    w.min_h = chance(0.5) ? 0 : real(0, 700);
                }
                break;
            }
        }
        if (chance(0.1)) {
            auto &[display, usable] = spaces_[s];
            usable = {real(-3000, 3000), real(-1500, 1500), real(900, 3200), real(700, 2000)};
            (void)display;
        }

        Snapshot snap;
        snap.space = s;
        snap.display = spaces_[s].first;
        snap.usable = spaces_[s].second;
        for (WindowId id : windows_on(s)) {
            const WorldWindow &w = windows_[id];
            snap.windows.push_back({id, w.state, {real(-100, 100), real(-100, 100), 300, 200}, w.min_w, w.min_h});
        }
        std::shuffle(snap.windows.begin(), snap.windows.end(), rng_);
        if (!snap.windows.empty() && chance(0.05)) {
            // A duplicate entry with a different state: the first occurrence must win.
            WindowInfo dup = snap.windows[static_cast<std::size_t>(uniform(0, int(snap.windows.size()) - 1))];
            dup.state = random_state();
            snap.windows.push_back(dup);
        }
        const int f = uniform(0, 9);
        if (f < 6 && !snap.windows.empty())
            snap.focused = snap.windows[static_cast<std::size_t>(uniform(0, int(snap.windows.size()) - 1))].id;
        else if (f < 8)
            snap.focused = 0;
        else
            snap.focused = random_window();
        return snap;
    }

    void forget_window(WindowId w) { windows_.erase(w); }

    // A destroyed space: its windows land on another space.
    void destroy_space(SpaceId s) {
        const SpaceId to = s == 1 ? 2 : 1;
        for (auto &[id, w] : windows_)
            if (w.space == s) w.space = to;
    }

private:
    std::mt19937_64 rng_;
    std::map<SpaceId, std::pair<DisplayId, Rect>> spaces_;
    std::map<WindowId, WorldWindow> windows_;
    WindowId next_id_ = 0;
};

std::set<WindowId> expected_tiled(const Snapshot &s) {
    std::set<WindowId> seen, tiled;
    for (const WindowInfo &w : s.windows) {
        if (!seen.insert(w.id).second) continue; // first occurrence wins
        if (w.state == WindowState::Tiled) tiled.insert(w.id);
    }
    return tiled;
}

struct Stats {
    int plans = 0;
    int degenerate = 0;
    int full_checks = 0;
};

void check_space(const Engine &e, SpaceId space, const Plan &plan, Stats &stats) {
    const Space *sp = e.model().find_space(space);
    REQUIRE(sp != nullptr);
    const LayoutResult l = e.layout_of(space);
    REQUIRE(l.placements.size() == plan.placements.size());
    for (std::size_t i = 0; i < l.placements.size(); ++i) {
        REQUIRE(l.placements[i].id == plan.placements[i].id);
        REQUIRE(l.placements[i].frame == plan.placements[i].frame);
    }
    const std::string problem = layout_problem(l, sp->usable, e.config().outer_gap);
    REQUIRE_MESSAGE(problem.empty(), problem << "\n" << e.debug_dump(space));
    ++stats.plans;
    if (l.degenerate) {
        ++stats.degenerate;
    } else if (!sp->tree.empty()) {
        // Full-tree identity with the configured gap: tiles + gaps == inner area.
        const double gaps = expected_gap_area(sp->tree.root(), l, e.config().inner_gap);
        REQUIRE(std::fabs(gaps - l.gap_area) <= 1e-6);
        ++stats.full_checks;
    }
}

} // namespace

TEST_SUITE("property") {

TEST_CASE("random operations keep every invariant (C++ engine)") {
    const long nodes_before = LayoutTree::live_node_count();
    Stats stats;
    {
        World world(0x5eed'cafe'f00dULL);
        Engine e;
        std::uint64_t last_rev = 0;
        for (int step = 0; step < kSteps; ++step) {
            CAPTURE(step);
            const int op = world.uniform(0, 99);
            if (op < 70) {
                const Snapshot s = world.step_snapshot(world.random_space());
                Plan p;
                REQUIRE(e.reconcile(s, p) == HM_OK);
                REQUIRE(p.revision > last_rev);
                last_rev = p.revision;
                std::string why;
                REQUIRE_MESSAGE(e.model().check_invariants(&why), why);
                const auto leaves = e.model().find_space(s.space)->tree.windows();
                REQUIRE(std::set<WindowId>(leaves.begin(), leaves.end()) == expected_tiled(s));
                REQUIRE(leaves.size() == e.tiled_count(s.space));
                for (WindowId w : leaves) REQUIRE(e.space_of(w) == s.space);
                check_space(e, s.space, p, stats);
            } else if (op < 78) {
                REQUIRE(e.set_config(world.random_config()) == HM_OK);
                for (const auto &[id, space] : e.model().spaces()) {
                    Plan p;
                    REQUIRE(e.relayout(id, p) == HM_OK);
                    REQUIRE(p.revision > last_rev);
                    last_rev = p.revision;
                    check_space(e, id, p, stats);
                }
            } else if (op < 86) {
                const WindowId w = world.random_window();
                const hm_status st = e.report_min_size(w, world.real(0, 1200), world.real(0, 900));
                REQUIRE(st == (e.space_of(w) ? HM_OK : HM_ERR_UNKNOWN_WINDOW));
                if (const SpaceId sid = e.model().tree_space_of(w)) {
                    Plan p;
                    REQUIRE(e.relayout(sid, p) == HM_OK);
                    last_rev = p.revision;
                    check_space(e, sid, p, stats);
                }
            } else if (op < 93) {
                const WindowId a = world.random_window(), b = world.random_window();
                const SpaceId sa = e.model().tree_space_of(a), sb = e.model().tree_space_of(b);
                Plan p;
                const hm_status st = e.swap(a, b, p);
                if (!sa || !sb) {
                    REQUIRE(st == HM_ERR_UNKNOWN_WINDOW);
                } else if (sa != sb) {
                    REQUIRE(st == HM_ERR_INVALID_ARGUMENT);
                } else {
                    REQUIRE(st == HM_OK);
                    last_rev = p.revision;
                    check_space(e, sa, p, stats);
                }
            } else if (op < 97) {
                const WindowId w = world.random_window();
                world.forget_window(w);
                e.forget_window(w);
                REQUIRE(e.space_of(w) == 0);
            } else {
                const SpaceId s = world.random_space();
                world.destroy_space(s);
                e.forget_space(s);
                REQUIRE(e.tiled_count(s) == 0);
            }
            std::string why;
            REQUIRE_MESSAGE(e.model().check_invariants(&why), why);
        }
        MESSAGE("plans checked: " << stats.plans << ", degenerate: " << stats.degenerate
                                  << ", full gap identities: " << stats.full_checks);
        CHECK(stats.full_checks > kSteps / 4);
    }
    CHECK(LayoutTree::live_node_count() == nodes_before);
}

TEST_CASE("random operations through the C API leak nothing") {
    const long nodes_before = LayoutTree::live_node_count();
    const long plans_before = diag::live_plan_buffers();
    World world(0xdead'beef'1234ULL);
    hm_engine *e = hm_engine_create(nullptr);
    REQUIRE(e != nullptr);
    hm_config cfg;
    hm_config_default(&cfg);
    std::set<SpaceId> known;
    std::uint64_t last_rev = 0;

    auto check_plan = [&](const hm_plan &p, SpaceId space, const Rect &usable) {
        REQUIRE(p.space == space);
        REQUIRE(p.revision > last_rev);
        last_rev = p.revision;
        REQUIRE(p.count == hm_engine_tiled_count(e, space));
        REQUIRE((p.count == 0) == (p.placements == nullptr));
        const Rect inner = inset(usable, cfg.outer_gap);
        double sum = 0;
        for (std::size_t i = 0; i < p.count; ++i) {
            const Rect f = Rect::from_c(p.placements[i].frame);
            REQUIRE(is_valid_rect(f));
            REQUIRE(f.w > 0);
            REQUIRE(f.h > 0);
            REQUIRE(contains(inner, f));
            REQUIRE(hm_engine_space_of(e, p.placements[i].id) == space);
            for (std::size_t j = i + 1; j < p.count; ++j)
                REQUIRE(intersection_area(f, Rect::from_c(p.placements[j].frame)) <= 1e-6);
            sum += f.area();
        }
        REQUIRE(sum <= inner.area() + 1e-6);
    };
    std::map<SpaceId, Rect> usable_of;

    for (int step = 0; step < kSteps; ++step) {
        CAPTURE(step);
        const int op = world.uniform(0, 99);
        if (op < 75) {
            const Snapshot s = world.step_snapshot(world.random_space());
            std::vector<hm_window_info> ws;
            for (const WindowInfo &w : s.windows) {
                hm_window_info c{};
                c.id = w.id;
                c.state = static_cast<hm_window_state>(w.state);
                c.frame = w.frame.to_c();
                c.min_w = w.min_w;
                c.min_h = w.min_h;
                ws.push_back(c);
            }
            hm_space_snapshot cs{s.display, s.space, s.usable.to_c(), s.focused, ws.data(), ws.size()};
            hm_plan p{};
            REQUIRE(hm_engine_reconcile(e, &cs, &p) == HM_OK);
            known.insert(s.space);
            usable_of[s.space] = s.usable;
            REQUIRE(p.count == expected_tiled(s).size());
            std::set<WindowId> got;
            for (std::size_t i = 0; i < p.count; ++i) got.insert(p.placements[i].id);
            REQUIRE(got == expected_tiled(s));
            check_plan(p, s.space, s.usable);
            hm_plan_free(&p);
        } else if (op < 82) {
            const Config c = world.random_config();
            cfg = c.to_c();
            REQUIRE(hm_engine_set_config(e, &cfg) == HM_OK);
            for (SpaceId id : known) {
                hm_plan p{};
                REQUIRE(hm_engine_relayout(e, id, &p) == HM_OK);
                check_plan(p, id, usable_of[id]);
                hm_plan_free(&p);
            }
        } else if (op < 88) {
            const WindowId w = world.random_window();
            const hm_status st = hm_engine_report_min_size(e, w, world.real(0, 1200), world.real(0, 900));
            REQUIRE(st == (hm_engine_space_of(e, w) ? HM_OK : HM_ERR_UNKNOWN_WINDOW));
        } else if (op < 94) {
            hm_plan p{};
            const hm_status st = hm_engine_swap(e, world.random_window(), world.random_window(), &p);
            REQUIRE((st == HM_OK || st == HM_ERR_UNKNOWN_WINDOW || st == HM_ERR_INVALID_ARGUMENT));
            if (st == HM_OK) check_plan(p, p.space, usable_of[p.space]);
            hm_plan_free(&p);
        } else if (op < 97) {
            const WindowId w = world.random_window();
            world.forget_window(w);
            hm_engine_forget_window(e, w);
            REQUIRE(hm_engine_space_of(e, w) == 0);
        } else {
            const SpaceId s = world.random_space();
            world.destroy_space(s);
            hm_engine_forget_space(e, s);
            known.erase(s);
            hm_plan p{};
            REQUIRE(hm_engine_relayout(e, s, &p) == HM_ERR_UNKNOWN_SPACE);
        }
        REQUIRE(diag::live_plan_buffers() == plans_before);
    }
    hm_engine_destroy(e);
    CHECK(LayoutTree::live_node_count() == nodes_before);
    CHECK(diag::live_plan_buffers() == plans_before);
}

} // TEST_SUITE
