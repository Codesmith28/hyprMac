/*
 * hypr_core.h — the ONLY interface between the Swift shell and the C++20 core.
 *
 * FROZEN CONTRACT (Phase 0). Changing a signature here requires updating
 * core/src/c_api.cpp, core/src/config_lua.cpp and macos/Sources/HyprKit.
 *
 * Conventions
 *  - Coordinates: logical points, top-left origin of the primary display,
 *    x grows right, y grows down (same convention as the Accessibility API).
 *  - All functions are NOT thread-safe; the caller serializes access to an
 *    engine (Swift uses a single serial coordinator queue).
 *  - Ids are opaque 64-bit values chosen by the caller. 0 is "none".
 *  - Memory returned through hm_plan is owned by the caller after return and
 *    must be released with hm_plan_free().
 *  - No function aborts on bad input; errors are reported via return codes.
 */
#ifndef HYPR_CORE_H
#define HYPR_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- basic types ---------- */

typedef uint64_t hm_window_id;  /* caller-built: (generation << 32) | CGWindowID */
typedef uint64_t hm_space_id;   /* native Space id (CGSSpaceID) or synthetic */
typedef uint32_t hm_display_id; /* CGDirectDisplayID */

typedef struct hm_rect {
    double x, y, w, h;
} hm_rect;

typedef enum hm_status {
    HM_OK = 0,
    HM_ERR_INVALID_ARGUMENT = 1, /* null pointer, non-finite rect, etc. */
    HM_ERR_UNKNOWN_SPACE = 2,
    HM_ERR_UNKNOWN_WINDOW = 3,
    HM_ERR_CONFIG = 4,           /* config file failed to load/validate */
    HM_ERR_INTERNAL = 99
} hm_status;

/* ---------- configuration ---------- */

typedef struct hm_config {
    double inner_gap;   /* px between adjacent tiles; default 8, range [0, 200] */
    double outer_gap;   /* px between tiles and usable-area edge; default 12, range [0, 200] */
    double split_ratio; /* ratio given to the FIRST child of a new split; default 0.5, range [0.1, 0.9] */
    double float_min_w; /* windows first seen narrower than this float; default 400, range [0, 2000], 0 = off */
    double float_min_h; /* windows first seen shorter than this float; default 300, range [0, 2000], 0 = off */
} hm_config;

/* Fill *out with built-in defaults. */
void hm_config_default(hm_config *out);

/* Validate *cfg. Returns HM_OK or HM_ERR_CONFIG and writes a human readable
 * reason to err (NUL-terminated, truncated to err_cap) when err != NULL. */
hm_status hm_config_validate(const hm_config *cfg, char *err, size_t err_cap);

/* Load a Lua config file (see config/init.lua.example).
 * On success writes the validated config to *inout and returns HM_OK.
 * On any failure (missing file, syntax error, runtime error, timeout,
 * invalid value) leaves *inout UNCHANGED, returns HM_ERR_CONFIG and writes
 * "<path>:<line>: <message>" (line when known) into err.
 * A missing file is reported as HM_ERR_CONFIG with message containing
 * "not found"; callers treat that as "use defaults", not as an error. */
hm_status hm_config_load_file(const char *path, hm_config *inout, char *err, size_t err_cap);

/* Same as hm_config_load_file but from an in-memory chunk (used by tests). */
hm_status hm_config_load_string(const char *lua_source, const char *chunk_name,
                                hm_config *inout, char *err, size_t err_cap);

/* ---------- engine ---------- */

typedef struct hm_engine hm_engine;

/* cfg may be NULL (defaults). Returns NULL only on allocation failure or
 * invalid cfg. */
hm_engine *hm_engine_create(const hm_config *cfg);
void hm_engine_destroy(hm_engine *engine);

/* Replace config. Does not produce a plan; call hm_engine_relayout for each
 * active space afterwards. */
hm_status hm_engine_set_config(hm_engine *engine, const hm_config *cfg);

/* Per-window state as observed by the platform layer. */
typedef enum hm_window_state {
    HM_WINDOW_TILED = 0,      /* eligible for tiling */
    HM_WINDOW_FLOATING = 1,   /* visible but not tiled (non-resizable, panel, rule) */
    HM_WINDOW_MINIMIZED = 2,  /* keep a ghost slot, restore on return */
    HM_WINDOW_FULLSCREEN = 3, /* keep a ghost slot, restore on return */
    HM_WINDOW_HIDDEN = 4      /* app hidden (Cmd-H); keep a ghost slot */
} hm_window_state;

typedef struct hm_window_info {
    hm_window_id id;
    hm_window_state state;
    hm_rect frame;        /* current actual frame (informational; may be 0s) */
    double min_w, min_h;  /* known minimum size, 0 when unknown */
} hm_window_info;

/* Snapshot of ONE (display, space) pair as currently visible.
 * windows[] lists every window the platform knows on this space, in
 * front-to-back order. Windows that were in this space's tree but are absent
 * from the snapshot are removed for good (closed or moved elsewhere).
 * A window id that currently belongs to a different space's tree is moved
 * (removed there without a ghost, inserted here). */
typedef struct hm_space_snapshot {
    hm_display_id display;
    hm_space_id space;
    hm_rect usable;          /* NSScreen.visibleFrame converted to top-left pts */
    hm_window_id focused;    /* 0 if no focused window on this space */
    const hm_window_info *windows;
    size_t window_count;
} hm_space_snapshot;

typedef struct hm_placement {
    hm_window_id id;
    hm_rect frame;
} hm_placement;

/* A geometry plan for one space. revision increases monotonically per
 * engine (across all spaces); the executor drops any write whose revision is
 * older than the latest plan it has seen for that window. */
typedef struct hm_plan {
    uint64_t revision;
    hm_space_id space;
    hm_placement *placements; /* malloc'd; free with hm_plan_free */
    size_t count;
} hm_plan;

void hm_plan_free(hm_plan *plan); /* safe on zeroed / already-freed plan */

/* Diff the snapshot against the stored tree for snapshot->space, mutate the
 * tree (insert new TILED windows dwindle-style at the focused leaf, remove
 * missing ones, ghost/restore MINIMIZED/FULLSCREEN/HIDDEN ones) and write the
 * full target geometry of every TILED window on that space into *out. */
hm_status hm_engine_reconcile(hm_engine *engine, const hm_space_snapshot *snapshot, hm_plan *out);

/* Recompute geometry for a space without changing membership (after config
 * change or min-size report). */
hm_status hm_engine_relayout(hm_engine *engine, hm_space_id space, hm_plan *out);

/* The platform discovered that a window refuses to be smaller than min_w x
 * min_h (read-back after a frame write). The next relayout honours it where
 * geometrically possible. */
hm_status hm_engine_report_min_size(hm_engine *engine, hm_window_id window, double min_w, double min_h);

/* Swap the tiles of two windows on the same space (used by future keybinds and
 * by drag-to-swap). Returns HM_ERR_UNKNOWN_WINDOW if either isn't tiled. */
hm_status hm_engine_swap(hm_engine *engine, hm_window_id a, hm_window_id b, hm_plan *out);

/* Drop a window everywhere, including ghost slots (app terminated). */
void hm_engine_forget_window(hm_engine *engine, hm_window_id window);

/* Drop a space's tree (space destroyed). */
void hm_engine_forget_space(hm_engine *engine, hm_space_id space);

/* Which space's tree (or ghost slot) currently holds this window; 0 if none. */
hm_space_id hm_engine_space_of(const hm_engine *engine, hm_window_id window);

/* Number of tiled leaves in a space (0 for unknown space). */
size_t hm_engine_tiled_count(const hm_engine *engine, hm_space_id space);

/* Debug: write a one-line-per-node textual dump of the space's tree into buf.
 * Returns the number of bytes that would have been written (snprintf style). */
size_t hm_engine_debug_dump(const hm_engine *engine, hm_space_id space, char *buf, size_t cap);

/* Library version string, e.g. "0.1.0". */
const char *hm_version(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* HYPR_CORE_H */
