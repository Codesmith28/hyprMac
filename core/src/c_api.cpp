// C boundary for the engine. Every entry point validates pointers, converts
// to the C++ types and never lets an exception escape (HM_ERR_INTERNAL).
#include "hypr/hypr_core.h"

#include "hypr/engine.hpp"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <new>
#include <type_traits>

struct hm_engine {
    hypr::Engine impl;
};

namespace {

std::atomic<long> g_live_plan_buffers{0};

// Read the enum through its underlying type so garbage values coming from the
// caller are rejected instead of being loaded as an out-of-range enum.
bool convert_state(const hm_window_state *src, hypr::WindowState &out) {
    std::underlying_type_t<hm_window_state> raw;
    static_assert(sizeof raw == sizeof *src);
    std::memcpy(&raw, src, sizeof raw);
    switch (raw) {
    case HM_WINDOW_TILED: out = hypr::WindowState::Tiled; return true;
    case HM_WINDOW_FLOATING: out = hypr::WindowState::Floating; return true;
    case HM_WINDOW_MINIMIZED: out = hypr::WindowState::Minimized; return true;
    case HM_WINDOW_FULLSCREEN: out = hypr::WindowState::Fullscreen; return true;
    case HM_WINDOW_HIDDEN: out = hypr::WindowState::Hidden; return true;
    default: return false;
    }
}

hm_status export_plan(const hypr::Plan &plan, hm_plan *out) {
    hm_placement *buf = nullptr;
    if (!plan.placements.empty()) {
        buf = static_cast<hm_placement *>(std::malloc(plan.placements.size() * sizeof(hm_placement)));
        if (!buf) return HM_ERR_INTERNAL;
        g_live_plan_buffers.fetch_add(1, std::memory_order_relaxed);
        for (std::size_t i = 0; i < plan.placements.size(); ++i)
            buf[i] = {plan.placements[i].id, plan.placements[i].frame.to_c()};
    }
    out->revision = plan.revision;
    out->space = plan.space;
    out->placements = buf;
    out->count = plan.placements.size();
    return HM_OK;
}

template <class F> hm_status guarded(F &&f) {
    try {
        return f();
    } catch (...) {
        return HM_ERR_INTERNAL;
    }
}

} // namespace

long hypr::diag::live_plan_buffers() { return g_live_plan_buffers.load(std::memory_order_relaxed); }

extern "C" {

const char *hm_version(void) { return "0.1.0"; }

hm_engine *hm_engine_create(const hm_config *cfg) {
    try {
        hypr::Config c;
        if (cfg) {
            c = hypr::Config::from_c(*cfg);
            if (!hypr::validate(c).empty()) return nullptr;
        }
        return new (std::nothrow) hm_engine{hypr::Engine(c)};
    } catch (...) {
        return nullptr;
    }
}

void hm_engine_destroy(hm_engine *engine) { delete engine; }

hm_status hm_engine_set_config(hm_engine *engine, const hm_config *cfg) {
    if (!engine || !cfg) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] { return engine->impl.set_config(hypr::Config::from_c(*cfg)); });
}

void hm_plan_free(hm_plan *plan) {
    if (!plan) return;
    if (plan->placements) {
        std::free(plan->placements);
        g_live_plan_buffers.fetch_sub(1, std::memory_order_relaxed);
    }
    plan->placements = nullptr;
    plan->count = 0;
}

hm_status hm_engine_reconcile(hm_engine *engine, const hm_space_snapshot *snapshot, hm_plan *out) {
    if (!engine || !snapshot || !out) return HM_ERR_INVALID_ARGUMENT;
    if (snapshot->window_count > 0 && !snapshot->windows) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Snapshot s;
        s.display = snapshot->display;
        s.space = snapshot->space;
        s.usable = hypr::Rect::from_c(snapshot->usable);
        s.focused = snapshot->focused;
        s.windows.reserve(snapshot->window_count);
        for (std::size_t i = 0; i < snapshot->window_count; ++i) {
            const hm_window_info &w = snapshot->windows[i];
            hypr::WindowInfo info;
            if (!convert_state(&w.state, info.state)) return HM_ERR_INVALID_ARGUMENT;
            info.id = w.id;
            info.frame = hypr::Rect::from_c(w.frame);
            info.min_w = w.min_w;
            info.min_h = w.min_h;
            s.windows.push_back(info);
        }
        hypr::Plan plan;
        if (hm_status st = engine->impl.reconcile(s, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_relayout(hm_engine *engine, hm_space_id space, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.relayout(space, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_report_min_size(hm_engine *engine, hm_window_id window, double min_w, double min_h) {
    if (!engine) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] { return engine->impl.report_min_size(window, min_w, min_h); });
}

hm_status hm_engine_swap(hm_engine *engine, hm_window_id a, hm_window_id b, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.swap(a, b, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_resize(hm_engine *engine, hm_window_id window, hm_rect desired, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.resize(window, hypr::Rect::from_c(desired), plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_resize_step(hm_engine *engine, hm_window_id window, hm_direction dir, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    std::underlying_type_t<hm_direction> raw;
    static_assert(sizeof raw == sizeof dir);
    std::memcpy(&raw, &dir, sizeof raw);
    hypr::Direction d;
    switch (raw) {
    case HM_DIR_LEFT: d = hypr::Direction::Left; break;
    case HM_DIR_DOWN: d = hypr::Direction::Down; break;
    case HM_DIR_UP: d = hypr::Direction::Up; break;
    case HM_DIR_RIGHT: d = hypr::Direction::Right; break;
    default: return HM_ERR_INVALID_ARGUMENT;
    }
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.resize_step(window, d, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_equalize(hm_engine *engine, hm_space_id space, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.equalize(space, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_rotate_split(hm_engine *engine, hm_window_id window, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.rotate_split(window, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_status hm_engine_toggle_zoom(hm_engine *engine, hm_window_id window, hm_plan *out) {
    if (!engine || !out) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan plan;
        if (hm_status st = engine->impl.toggle_zoom(window, plan); st != HM_OK) return st;
        return export_plan(plan, out);
    });
}

hm_window_id hm_engine_zoomed_window(const hm_engine *engine, hm_space_id space) {
    return engine ? engine->impl.zoomed_window(space) : 0;
}

void hm_engine_clear_zoom(hm_engine *engine, hm_space_id space) {
    if (!engine) return;
    try {
        engine->impl.clear_zoom(space);
    } catch (...) {
    }
}

hm_status hm_engine_move_to_space(hm_engine *engine, hm_window_id window, hm_space_id target_space,
                                  hm_plan *out_target, hm_plan *out_source) {
    if (!engine || !out_target || !out_source) return HM_ERR_INVALID_ARGUMENT;
    return guarded([&] {
        hypr::Plan to, from;
        if (hm_status st = engine->impl.move_to_space(window, target_space, to, from); st != HM_OK) return st;
        if (hm_status st = export_plan(to, out_target); st != HM_OK) return st;
        if (hm_status st = export_plan(from, out_source); st != HM_OK) {
            hm_plan_free(out_target);
            return st;
        }
        return HM_OK;
    });
}

void hm_engine_forget_window(hm_engine *engine, hm_window_id window) {
    if (!engine) return;
    try {
        engine->impl.forget_window(window);
    } catch (...) {
    }
}

void hm_engine_forget_space(hm_engine *engine, hm_space_id space) {
    if (!engine) return;
    try {
        engine->impl.forget_space(space);
    } catch (...) {
    }
}

hm_space_id hm_engine_space_of(const hm_engine *engine, hm_window_id window) {
    if (!engine || window == 0) return 0;
    return engine->impl.space_of(window);
}

size_t hm_engine_tiled_count(const hm_engine *engine, hm_space_id space) {
    if (!engine) return 0;
    return engine->impl.tiled_count(space);
}

size_t hm_engine_debug_dump(const hm_engine *engine, hm_space_id space, char *buf, size_t cap) {
    if (buf && cap) buf[0] = '\0';
    if (!engine) return 0;
    try {
        const std::string s = engine->impl.debug_dump(space);
        if (buf && cap) {
            const std::size_t n = std::min(s.size(), cap - 1);
            std::memcpy(buf, s.data(), n);
            buf[n] = '\0';
        }
        return s.size();
    } catch (...) {
        return 0;
    }
}

} // extern "C"
