# hyprMac checkpoint: resume here

> Read this first when you pick the project up again.
> Update it at each milestone: merges, real-Mac runs, budget decisions.
> Last updated: 2026-10-31. Full plan: `~/.claude/plans/frolicking-gathering-journal.md`.

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
| Signing | Ad-hoc. Install and upgrade both reset the Accessibility entry (`tccutil reset`), since the cdhash changes each build |
| Insertion | Dwindle: split the focused tile along its longer side; the new window goes second |
| Login | LaunchAgent `~/Library/LaunchAgents/dev.codesmith28.hyprmac.plist` |
| Rectangle | Warn once, never touch it |
| Stack | C++20 core (`core/`), Swift/AppKit shell (`macos/`), vendored Lua 5.4.7, GNU make. Command Line Tools only, no Xcode |

## Build and test (always through make)
- `make test`: core doctest, `swift test` and the sandboxed install tests. No permissions needed. **Never run plain `swift test`**; `mk/swift.mk` passes the Swift Testing plugin paths.
- `make test-asan`, `make bench`, `make app` (→ `build/hyprMac.app`), `make run`.
- `make preflight` (read-only), `make install [DRY_RUN=1]`, `make uninstall`, `make verify-rollback`.
- `make test-e2e E2E_ARGS="--keep-going"` is the real-Mac run. It posts real keys and switches Spaces, so run it only with the user watching. The runbook is in `docs/TESTING.md`.

## Status (as of 2026-10-31)
All feature and fix branches are merged to `main`. The latest merge is `feat/user-resize`. Last `make test` counts: core 201, platform 188, kit 127, install-sandbox 29. All green.

Real-Mac history: the latest e2e run was 32 passed, 2 failed, 1 skipped of 35. The user confirmed the build works on their Mac after a logout.

### Open items
- **`hung-app-isolation`** is flaky. SIGHUP → `config_loaded` takes 517–546 ms against a 500 ms limit. Raise the limit to 750 ms, or load config off the coordinator queue.
- **`fullscreen-restore`**: window A1 gets floated for "fights" when it leaves fullscreen. It also fails on the earlier base, and Rectangle was running. Not investigated yet.
- **Known gap:** re-tiling with ⌥⇧F inserts at the most recently inserted leaf, not the focused leaf. Fixing it needs an engine and C API change.
- **Known gap:** the source Space can't be resized while hidden, so it retiles when next shown.

### Next steps
1. Confirm the installed app is the latest build. If not, run `make install` as an upgrade.
2. Real-Mac pass: a short e2e subset, then a manual ⌥⇧2 throw in Ghostty.
3. `make uninstall`. It must print "rollback verified". Then run `make verify-rollback`.
4. Record the results here and commit.
5. Clean up the five git worktrees (`hyprMac-core`, `-e2e`, `-install`, `-platform` and the sibling dirs) once nothing needs them.

### Deferred findings (list as known gaps)
- **Rollback review:** H3 (the snapshot is too narrow, so collateral changes to other keys go undetected), H4 (the sandbox guard can be bypassed; tests only), M2 (a preloaded LaunchAgent isn't restored), M3 (an interrupted install that is re-run is treated as an upgrade), M5 (TCC reset is lossy, and a BTM disabled override persists), M6 (an already-running app isn't detected), M7 (a user-edited config is deleted), L1–L8. C1, H1, H2, M4, M8 and M9 are fixed.
- **Live review:** #8 (Carbon can't detect ⌥⇧N clashes), #9 (NSScreen read off main), #11 (thread leak per restart, executor queue pruning). #1–7, #10 and #11 are mostly fixed.
- **Performance:** dwindle insertion of N windows arriving at once is O(n²) (1.3 ms for 200). Doesn't matter in practice.

## Budget
About $13 was left on 2026-10-31. Run agents on Sonnet. If a fix agent stalls (no working fix after about 40 minutes, or the next e2e run still swaps windows), switch that agent to Opus, then checkpoint. Keep budget for the merge, the reinstall and `make uninstall`. If the budget runs out, `make uninstall` restores everything, and you resume from this file.

## Orchestration notes
- Each workstream owns disjoint paths. The frozen C API is `core/include/hypr/hypr_core.h`.
- Agents work in worktrees on `feat/*` or `fix/*` branches. The orchestrator merges with `--no-ff` and runs `make test` after each merge.
- Only one agent may run the real e2e suite at a time. It stops the installed hyprMac (`launchctl kill`) while it runs.
- Agents can block on permission prompts. The orchestrator must not answer them. They auto-decline after about 2 minutes, or the user answers in the pane.
- Herdr commands: `herdr agent list`, `herdr agent prompt <name> "..."`, `herdr agent wait <name> --until idle --until done`.
