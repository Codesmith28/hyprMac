# hyprMac checkpoint: resume here

> **Read this first** when you restart work on this project, whether you're a person or an agent.
> Update it at every milestone: merges, the real run, budget decisions.
> Last updated: 2026-10-31 by the orchestrator (Claude). The plan is in `~/.claude/plans/frolicking-gathering-journal.md`.

## Goal
Hyprland-style BSP tiler for macOS on **native** Spaces:
- automatic tiling with gaps;
- ⌥1–9 native Space switching (hyprMac only listens);
- ⌥⇧1–9 throws the focused window via the drag trick;
- fullscreen, minimized and hidden windows are left alone and restored;
- each display tiled independently.

`make install` / `make uninstall` must restore the **exact** pre-install state, and `verify-rollback` proves it.

## Decisions (agreed with the user; don't re-ask)
| Topic | Decision |
|---|---|
| Throw window (⌥⇧N) | Amethyst-style drag trick: no SIP change, no private write APIs |
| ⌥N | Native symbolic hotkeys stay. Install adds ⌥8/⌥9 (ids 125/126) only if absent, and uninstall restores them |
| Stage Manager | Install records the value and sets it off; uninstall restores the recorded value. **The user turned Stage Manager off by hand on 2026-10-31**, so the recorded "original" will be OFF. Writing the pref doesn't apply live: toggle it in Control Center or log out |
| Signing | Ad-hoc. Install runs `tccutil reset Accessibility dev.codesmith28.hyprmac` |
| Insertion | Dwindle: split the focused tile along its longer side; the new window goes second |
| Login | LaunchAgent `~/Library/LaunchAgents/dev.codesmith28.hyprmac.plist` |
| Rectangle | Warn once, never touch it |
| Stack | C++20 core (`core/`), Swift/AppKit shell (`macos/`), vendored Lua 5.4.7 config, GNU make. No Xcode (Command Line Tools only) |

## Build / test (all through make)
- **`make test`** runs core doctest, `swift test` and the sandboxed install tests. It needs no permissions.
  - Swift Testing on Command Line Tools needs explicit plugin paths; `mk/swift.mk` handles that. **Never call plain `swift test`.**
- **`make test-asan`, `make bench`, `make app`** (→ `build/hyprMac.app`), **`make run`**.
- **`make preflight`** (read-only), **`make install [DRY_RUN=1]`**, **`make uninstall`**, **`make verify-rollback`**.
- **`make test-e2e E2E_ARGS="--keep-going"`** is the real-macOS run: it posts real keys and switches Spaces. Run it only with the user watching. The runbook is in `docs/TESTING.md`.

## Status
### Merged to `main` (all green at merge time)
| Branch | Content |
|---|---|
| `feat/core` + `feat/hardening` | C++ engine: 169 doctest cases including property tests, ASan clean, `make bench` (p99 1.9 µs at 10 windows) |
| `feat/install` + `feat/install-hardening` | Lua loader; manifest-based install/uninstall; preflight and DRY_RUN; signal-only quit; exact-path lsregister |
| `feat/platform` | HyprPlatform adapters + FakeAX simulator (143 tests) |
| `feat/kit` | Coordinator (`macos/Sources/HyprKit/Coordinator.swift`) + 69 integration tests |
| `feat/e2e`, `feat/app-contract`, `feat/e2e-v2` | Fixture app + E2E harness (scenarios plus v2 throw scenarios), app ↔ harness contract |
| `feat/docs` | README, `docs/USAGE.md`, `LIMITATIONS.md`, `TESTING.md` (refreshed in e2e-v2) |

### Merged since (2026-10-31, all green: core 169, platform 170, kit 70, install-sandbox 29)
| Branch | Content |
|---|---|
| `feat/e2e-v2` | v2 throw scenarios, fixture titlebar variants, docs refresh |
| `fix/live-review` | AX timeout (system-wide 0.25 s), one-call `facts()`, observers off main, Ghostty grab point (top+3 band), mouse flags, non-blocking `isPaused` |
| `fix/rollback-review` | Manifest allowlist (C1), keep state on failed undo (H1), journaled undo (H2), `-dict-add` hotkeys (M4), exit 3 = UNVERIFIED (M9), refuse root/empty HOME (M8) |

### In progress
Nothing is running in the background. The only unmerged work is the half-written `scripts/tests/regressions.sh` (uncommitted, in the `hyprMac-core` worktree; optional).

### Next steps
1. **Real run:** `make preflight` and `make install DRY_RUN=1` were checked and are clean. Next are `make install`, a short e2e subset, a manual ⌥⇧2 on Ghostty, then `make uninstall` (it must print "rollback verified") and `make verify-rollback`.
2. Record the results here, and commit.

### Known open findings (deferred for budget; list them as known gaps)
- **Rollback review (C1/H1/H2/M4/M8/M9 are FIXED):** H3 (the snapshot is too narrow: collateral damage to other keys isn't detected), H4 (the sandbox guard can be bypassed; affects tests only), M2 (a preloaded LaunchAgent isn't restored), M3 (an interrupted install that is re-run gets treated as an upgrade), M5 (TCC reset is lossy; a BTM disabled override persists), M6 (an already-running app isn't detected), M7 (a user-edited config is deleted), L1–L8.
- **Live review (#1-#7, #10, #11 mostly FIXED):** #8 (Carbon can't detect ⌥⇧N clashes), #9 (NSScreen read off main), #11 (thread leak per restart, executor queue pruning).
- **Perf:** dwindle insertion of N windows arriving at once is O(n²) (1.3 ms for 200); irrelevant in practice.

## Orchestration notes for whoever resumes
- **Ownership:** each workstream owns disjoint paths. The frozen C API is `core/include/hypr/hypr_core.h`. Agents work in worktrees on `feat/*` or `fix/*` branches; the orchestrator merges with `--no-ff`.
- **Model:** to save budget, run agents with `claude --model sonnet --effort high --permission-mode auto`.
- **Permission prompts:** agents can block on them. The orchestrator may NOT answer them; they auto-decline after about 2 minutes, or the user answers in the pane.
- **Herdr commands:** `herdr agent list`, `herdr agent prompt <name> "..."`, `herdr agent wait <name> --until idle --until done`.
