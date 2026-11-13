# hyprMac checkpoint: resume here

> Read this first when you pick the project up again.
> Update it at each milestone: releases, merges, real-Mac runs.
> Last updated: 2026-11-13.

## Goal
A Hyprland-style BSP tiler for macOS that uses **native** Spaces:
- automatic tiling with gaps;
- ⌥1–9 switch Spaces with macOS's own shortcuts (hyprMac only listens);
- ⌥⇧1–9 throw the focused window using the drag trick;
- fullscreen, minimized and hidden windows keep their tile and return to it;
- each display is tiled independently.

`make install` and `make uninstall` must restore the **exact** pre-install state. `make verify-rollback` proves it.

## Decisions (agreed with the user; don't re-ask)

| Topic | Decision |
|---|---|
| Throwing (⌥⇧N) | Drag trick, like Amethyst. No SIP change, no private write APIs |
| ⌥N | Native symbolic hotkeys stay. Install adds ⌥8/⌥9 (ids 125/126) only if they're free. Uninstall restores them |
| Stage Manager | Install records the value and sets it off. Uninstall restores the recorded value. The user turned it off by hand on 2026-10-31, so the recorded original is OFF. The pref write doesn't apply live: toggle it in Control Center or log out |
| Signing | Ad-hoc by default. Install and upgrade both reset the Accessibility entry (`tccutil reset`), since the cdhash changes each build. Opt-in stable identity: `make sign-identity` (see [limitations](LIMITATIONS.md#accessibility-permission-resets-on-reinstall)) |
| Insertion | Dwindle: split the focused tile along its longer side; the new window goes second |
| Login | LaunchAgent `~/Library/LaunchAgents/dev.codesmith28.hyprmac.plist` |
| Rectangle | Warn once, never touch it |
| Stack | C++20 core (`core/`), Swift/AppKit shell (`macos/`), vendored Lua 5.4.7, GNU make. Command Line Tools only, no Xcode |

## Build and test (always through make)
- `make test`: core doctest, `swift test` and the sandboxed install tests. No permissions needed. **Never run plain `swift test`**; `mk/swift.mk` passes the Swift Testing plugin paths.
- `make test-asan`, `make bench`, `make app` (→ `build/hyprMac.app`), `make run`.
- CI (`.github/workflows/ci.yml`) runs `make test` and `make test-asan` on every push and PR. Pushing a `v*` tag runs `release.yml`: it checks the tag against `Info.plist`, builds, zips with `ditto`, and publishes a GitHub release with the CHANGELOG section as notes. Homebrew cask template: `packaging/homebrew/`.
- `make preflight` (read-only), `make install [DRY_RUN=1]`, `make uninstall`, `make verify-rollback`.
- `make test-e2e E2E_ARGS="--keep-going"` is the real-Mac run. It posts real keys and switches Spaces, so run it only with the user watching. The runbook is in `docs/TESTING.md`.

## Status (as of 2026-11-13)
Released: v0.2.2 (`Info.plist` and the latest tag in `CHANGELOG.md`). v0.3.0 is in progress on `release/v0.3.0`. Last full `make test` counts on that base: core 205, platform 210, kit 161, install-sandbox 29, all green.

Real-Mac history: the latest recorded e2e run (2026-10-31) was 32 passed, 2 failed, 1 skipped of 35. Re-run it before a release; the open items below were last seen then.

### Open items
- **`hung-app-isolation`** is flaky. SIGHUP → `config_loaded` takes 517–546 ms against a 500 ms limit. Raise the limit to 750 ms, or load config off the coordinator queue.
- **`fullscreen-restore`**: window A1 gets floated for "fights" when it leaves fullscreen. It also failed on the earlier base, and Rectangle was running. Not investigated yet.
- **Known gap:** re-tiling with ⌥⇧F inserts at the most recently inserted leaf, not the focused leaf. Fixing it needs an engine and C API change.
- **Known gap:** the source Space can't be resized while hidden, so it retiles when next shown.
- **Docs/code mismatch:** the shipped `init.lua.example` sets every `focus_*` / `move_*` key, and setting any key in a group replaces its defaults, so the arrow-key variants don't work with the example config. [Usage](USAGE.md) says so.

### Release steps
1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `macos/Resources/Info.plist` and add the CHANGELOG section (template: `.github/CHANGELOG_TEMPLATE.md`).
2. `make test` and `make test-asan`. On a real Mac, `make test-e2e` and a manual ⌥⇧2 throw.
3. Merge, then tag: `git tag vX.Y.Z && git push origin vX.Y.Z`. The release workflow does the rest.
4. Optional: update your Homebrew tap (`packaging/homebrew/README.md`).

### Deferred findings (list as known gaps)
- **Rollback review:** H3 (the snapshot is too narrow, so collateral changes to other keys go undetected), H4 (the sandbox guard can be bypassed; tests only), M2 (a preloaded LaunchAgent isn't restored), M3 (an interrupted install that is re-run is treated as an upgrade), M5 (TCC reset is lossy, and a BTM disabled override persists), M6 (an already-running app isn't detected), L1–L8. C1, H1, H2, M4, M7 (an edited config now goes to the Trash), M8 and M9 are fixed.
- **Live review:** #8 (Carbon can't detect ⌥⇧N clashes), #9 (NSScreen read off main), #11 (thread leak per restart, executor queue pruning). #1–7, #10 and #11 are mostly fixed.
- **Performance:** dwindle insertion of N windows arriving at once is O(n²) (1.3 ms for 200). Doesn't matter in practice.

## Working notes
- Each workstream owns disjoint paths. The frozen C API is `core/include/hypr/hypr_core.h`.
- Work happens on `feat/*` or `fix/*` branches, merged with `--no-ff` after `make test`.
- Only one run of the real e2e suite at a time. It stops the installed hyprMac (`launchctl kill`) while it runs.
