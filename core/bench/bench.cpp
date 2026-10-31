// make bench: reconcile + layout latency through the C API (what the Swift app calls).
//
// For 1, 10, 50 and 200 windows on one Space it measures
//   steady  - the same snapshot again (diff finds nothing, full layout + plan export)
//   churn   - one window alternately minimized and restored (ghost + exact restore)
//   cold    - all N windows arrive in one snapshot on an empty engine
// and then 10 000 random reconciles over 3 Spaces (opens, closes, state changes, moves,
// focus and usable-rect changes). Times include building the plan and hm_plan_free.
#include "hypr/hypr_core.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

struct Stats {
    double p50 = 0, p99 = 0, mean = 0, max = 0;
};

Stats summarize(std::vector<double> us) {
    Stats s;
    if (us.empty()) return s;
    std::sort(us.begin(), us.end());
    double sum = 0;
    for (double v : us) sum += v;
    s.mean = sum / static_cast<double>(us.size());
    s.p50 = us[us.size() / 2];
    s.p99 = us[std::min(us.size() - 1, us.size() * 99 / 100)];
    s.max = us.back();
    return s;
}

std::size_t g_sink = 0; // keeps the optimizer honest

double timed_reconcile(hm_engine *e, const hm_space_snapshot &snap) {
    hm_plan plan{};
    const auto t0 = Clock::now();
    const hm_status st = hm_engine_reconcile(e, &snap, &plan);
    g_sink += plan.count;
    hm_plan_free(&plan);
    const auto t1 = Clock::now();
    if (st != HM_OK) {
        std::fprintf(stderr, "reconcile failed: %d\n", static_cast<int>(st));
        std::exit(1);
    }
    return std::chrono::duration<double, std::micro>(t1 - t0).count();
}

hm_space_snapshot make_snapshot(hm_space_id space, const std::vector<hm_window_info> &ws, hm_window_id focused,
                                hm_rect usable = {0, 0, 2560, 1415}) {
    return {1, space, usable, focused, ws.empty() ? nullptr : ws.data(), ws.size()};
}

std::vector<hm_window_info> windows(std::size_t n) {
    std::vector<hm_window_info> ws(n);
    for (std::size_t i = 0; i < n; ++i) {
        ws[i] = {};
        ws[i].id = n - i; // front to back: newest first
        ws[i].state = HM_WINDOW_TILED;
    }
    return ws;
}

void print(const char *label, std::size_t n, const Stats &s) {
    std::printf("  %-7s n=%-4zu p50 %8.2f us   p99 %8.2f us   mean %8.2f us   max %8.2f us\n", label, n, s.p50,
                s.p99, s.mean, s.max);
}

Stats bench_size(std::size_t n, int iterations) {
    // cold: N new windows in one snapshot
    {
        std::vector<double> samples;
        const int cold_runs = n >= 200 ? 20 : 200;
        auto ws = windows(n);
        for (int r = 0; r < cold_runs; ++r) {
            hm_engine *e = hm_engine_create(nullptr);
            samples.push_back(timed_reconcile(e, make_snapshot(1, ws, 0)));
            hm_engine_destroy(e);
        }
        print("cold", n, summarize(samples));
    }

    hm_engine *e = hm_engine_create(nullptr);
    auto ws = windows(n);
    const hm_space_snapshot snap = make_snapshot(1, ws, ws.front().id);
    timed_reconcile(e, snap); // build the tree

    for (int i = 0; i < 50; ++i) timed_reconcile(e, snap); // warm-up
    std::vector<double> steady;
    steady.reserve(static_cast<std::size_t>(iterations));
    for (int i = 0; i < iterations; ++i) steady.push_back(timed_reconcile(e, snap));
    const Stats s = summarize(steady);
    print("steady", n, s);

    std::vector<double> churn;
    auto toggled = ws;
    hm_window_info &victim = toggled[toggled.size() / 2];
    for (int i = 0; i < iterations; ++i) {
        victim.state = (i % 2 == 0) ? HM_WINDOW_MINIMIZED : HM_WINDOW_TILED;
        churn.push_back(timed_reconcile(e, make_snapshot(1, toggled, ws.front().id)));
    }
    print("churn", n, summarize(churn));
    hm_engine_destroy(e);
    return s;
}

Stats bench_random(int steps) {
    std::mt19937_64 rng(0xbe9c4);
    auto uniform = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    struct Win {
        hm_space_id space;
        hm_window_state state;
    };
    std::map<hm_window_id, Win> world;
    hm_window_id next = 0;
    std::map<hm_space_id, hm_rect> usable{{1, {0, 0, 2560, 1415}}, {2, {0, 0, 2560, 1415}},
                                          {3, {-1920, 0, 1920, 1055}}};
    hm_engine *e = hm_engine_create(nullptr);
    std::vector<double> samples;
    samples.reserve(static_cast<std::size_t>(steps));
    std::size_t total_windows = 0;
    for (int i = 0; i < steps; ++i) {
        const hm_space_id s = static_cast<hm_space_id>(uniform(1, 3));
        for (int m = uniform(0, 3); m > 0; --m) {
            switch (uniform(0, 4)) {
            case 0:
                if (world.size() < 30) world[++next] = {s, HM_WINDOW_TILED};
                break;
            case 1:
                if (!world.empty()) world.erase(std::next(world.begin(), uniform(0, int(world.size()) - 1)));
                break;
            case 2:
            case 3:
                if (!world.empty()) {
                    Win &w = std::next(world.begin(), uniform(0, int(world.size()) - 1))->second;
                    w.state = uniform(0, 1) ? HM_WINDOW_TILED : static_cast<hm_window_state>(uniform(1, 4));
                }
                break;
            case 4:
                if (!world.empty()) std::next(world.begin(), uniform(0, int(world.size()) - 1))->second.space = s;
                break;
            }
        }
        if (uniform(0, 19) == 0) usable[s].w = 1200 + uniform(0, 1400);
        std::vector<hm_window_info> ws;
        for (const auto &[id, w] : world) {
            if (w.space != s) continue;
            hm_window_info info{};
            info.id = id;
            info.state = w.state;
            ws.push_back(info);
        }
        std::shuffle(ws.begin(), ws.end(), rng);
        total_windows += ws.size();
        const hm_window_id focused = ws.empty() ? 0 : ws.front().id;
        samples.push_back(timed_reconcile(e, make_snapshot(s, ws, focused, usable[s])));
    }
    hm_engine_destroy(e);
    double total = 0;
    for (double v : samples) total += v;
    const Stats st = summarize(samples);
    std::printf("  random  %d reconciles, avg %.1f windows/snapshot, total %.2f ms\n", steps,
                static_cast<double>(total_windows) / steps, total / 1000.0);
    print("random", static_cast<std::size_t>(steps), st);
    return st;
}

} // namespace

int main() {
    std::printf("hyprMac core %s: reconcile + layout latency (C API, plan export + free included)\n", hm_version());
    Stats ten;
    for (std::size_t n : {1u, 10u, 50u, 200u}) {
        const Stats s = bench_size(n, n >= 200 ? 2000 : 20000);
        if (n == 10) ten = s;
    }
    bench_random(10000);
    const double target = 50.0;
    std::printf("target: < %.0f us per reconcile at 10 windows -> p50 %.2f us, p99 %.2f us: %s\n", target, ten.p50,
                ten.p99, ten.p99 < target ? "PASS" : "FAIL");
    return g_sink == 0 ? 1 : 0;
}
