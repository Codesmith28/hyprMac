# Testing hyprMac

A tiler is hard to test: its input is the live macOS desktop, and its output is other apps' windows. hyprMac is split so that almost everything can be tested **without** a desktop, and the part that can't is tested by a separate end-to-end harness on the real Mac.

```
                       ▲  real macOS, needs Accessibility, minutes
                 ┌─────┴─────┐
                 │    E2E    │  hyprmac-e2e + fixture app: 23 scenarios
                 ├───────────┤
                 │  install  │  install/uninstall in a fake HOME with command shims
               ┌─┴───────────┴─┐
               │ Swift + FakeAX│  platform + coordinator against a simulated desktop
             ┌─┴───────────────┴─┐
             │  property tests   │  10,000 random steps, invariants after each
           ┌─┴───────────────────┴─┐
           │   C++ unit (doctest)  │  layout tree, geometry, engine, C API, Lua config
           └───────────────────────┘
                       ▼  no permissions, seconds
```

`make test` runs the bottom four layers (`core-test`, `swift-test`, `scripts-test`). None of them needs any permission or touches the real system.

## 1. C++ core: doctest
`make core-test` builds and runs `core/tests/*` with [doctest](https://github.com/doctest/doctest), vendored in the repo:

| Area | File |
|---|---|
| layout tree (insert, remove, wrap, swap, validation) | `layout_tree_tests.cpp` |
| BSP geometry (gaps, ratios, min sizes, degenerate screens) | `bsp_layout_tests.cpp` |
| geometry helpers | `geometry_tests.cpp` |
| engine reconcile, ghost slots, multi-Space | `engine_tests.cpp` |
| workspace model | `workspace_model_tests.cpp` |
| the frozen C API (`hypr_core.h`) | `c_api_tests.cpp` |
| config validation | `config_validate_tests.cpp` |
| Lua loader and sandbox | `config_lua_tests.cpp` |

The Lua loader tests cover:
- syntax and runtime errors, which must report the file and line;
- NaN and out-of-range values;
- unknown keys, with "did you mean" suggestions;
- binary chunks;
- files over 256 KB;
- infinite loops, including ones hidden behind `pcall` or `__close` (the instruction limit);
- memory bombs (the 8 MB allocator cap);
- attempts to reach `io`, `os`, `require`, `load` or `debug`.

`make test-asan` runs the same tests under AddressSanitizer and UndefinedBehaviorSanitizer.

## 2. Property tests
`core/tests/property_tests.cpp` builds a simulated "world" of windows on three Spaces and mutates it at random for 10,000 steps:
- opening and closing windows;
- changing a window's state (minimized, hidden, fullscreen, floating);
- moving a window to another Space, sometimes as a fullscreen window;
- adding minimum-size hints;
- switching to a random config.

After each step it feeds the engine a snapshot and checks:
- the tree's internal invariants hold;
- the tiled leaves are exactly the world's tiled windows on that Space;
- plan revisions only increase;
- the plan matches the computed layout;
- tile areas plus gap areas add up to the usable area.

A second test drives the same random walk through the C API and checks that no tree nodes leak.

## 3. Swift: the FakeAX quirk simulator
`make swift-test` runs the Swift Testing suites in `macos/Tests/`. The platform layer talks to macOS only through protocols (`AXBackend`, `SpaceProvider`, `DisplayProvider` and so on). `HyprPlatform/Fakes/FakeDesktop.swift` implements them as an in-memory desktop with displays, Spaces, apps and windows.

Each fake window can be given the real-world quirks hyprMac must survive:
- `minSize`, plus `exposesMinSize` for the rare app that reports it;
- `clampToDisplay`, for apps that need size → position → size;
- `notReadyCalls`, where the first K Accessibility calls fail, as with windows that are still opening;
- `closesOnWrite`, a window that disappears mid-write;
- `snapsBack`, an app that reverts its own size;
- `titlebarRegions`, for tabs and buttons under the titlebar that the drag trick must avoid.

The tests cover these areas:
- window eligibility;
- discovery and Space membership;
- the geometry executor (retries, echo filtering, min-size discovery);
- AX observers;
- input (hotkeys, the ⌥N tap filter, event posting);
- Space parsing and the synthetic fallback;
- the drag-trick mover;
- configuration and app options.

**Coordinator integration tests** (`macos/Tests/HyprKitTests/`) run the real `Coordinator` with the real C++ engine against the same fake desktop. Each test waits until the coordinator is idle, then asserts the actual fake window frames:
- exact layouts, reflow, and dwindle following focus;
- ghosts: minimize, hide and fullscreen return to the same rectangle;
- per-Space trees, two displays, and negative coordinates;
- min-size relayout;
- snap-back windows floated after 3 fights without looping, and **Retile All Windows** forgiving them;
- echo filtering and drag handling;
- a hung app not blocking another app;
- every throw result, including retrying `transitionInFlight`;
- Stage Manager, Rectangle, permission loss and config reload;
- delegate re-entrancy.

## 4. Install scripts in a sandbox
`make scripts-test` runs `scripts/tests/run.sh`. Every scenario gets a fresh fake `HOME` and a fake `hyprMac.app`. Every system command the scripts use goes through a variable (`DEFAULTS`, `LAUNCHCTL`, `TCCUTIL`, `LSREGISTER`, …), and in the tests each one points at a shim in `scripts/tests/shims/`.

A guard (`HYPR_SANDBOX=1`) refuses to run in these cases:
- any command still points at a real system path;
- `HOME` is the real home directory.

The scenarios cover:
- a clean install → uninstall round trip with zero snapshot difference;
- upgrade;
- uninstall without an install;
- a failure injected at **every** install step, which must roll back cleanly;
- pre-existing ⌥8/⌥9 bindings, left untouched;
- unrelated hotkey changes made after install;
- Stage Manager absent, on and off;
- a pre-existing config, and `KEEP_CONFIG`;
- pre-existing app data and an existing app bundle;
- changed notification settings;
- dry runs;
- uninstalling from the copy inside the bundle;
- `verify-rollback` detecting a deliberate divergence;
- quitting the app with signals only (`launchctl kill` on the agent, else `pkill`, then `SIGKILL`);
- LaunchServices records counted for the installed path only, so a registered build copy doesn't break verification;
- Stage Manager read back as off after the write;
- crash-report residue;
- `make install DRY_RUN=1` and `make preflight` changing nothing.

## 5. End-to-end on the real Mac
Two extra executables are built with the app:
- **`hyprmac-fixture`** is a small, scriptable AppKit app. Flags control its windows: count, minimum size, non-resizable, native tabs, a sheet, panel or dialog, snapping back after a resize, slow resizes, opening late, hanging its main thread, going fullscreen, and the titlebar style (`--titlebar standard|transparent|tabs|toolbar`). It takes commands on stdin (`open`, `close i`, `minimize i`, `fullscreen i`, `hide`, `focus i`, `quit`, …) and reports every window and action as JSON lines on stdout. Each window's `windowNumber` equals its `CGWindowID`.
- **`hyprmac-e2e`** launches the real `hyprMac.app` and the fixture for each scenario. It reads the actual window frames through Accessibility, cross-checks them against `CGWindowList`, and compares them with a **geometry oracle**: an independent Swift implementation of the dwindle layout that shares no code with the C++ engine. Frames must match within ±1 pt after they have been still for 300 ms.

### The app's test contract
The harness launches `hyprMac.app/Contents/MacOS/hyprMac --config <file> --event-log <file>`. With `--event-log`, the app appends one JSON object per line:

| Event | When |
|---|---|
| `{"event":"started"}` | first, at launch |
| `{"event":"config_loaded","inner":8,"outer":12}` / `{"event":"config_error","message":"…"}` | after every config load, including at startup and on reload |
| `{"event":"paused","reason":"stage_manager"\|"accessibility"\|"user"}` | when tiling is paused |
| `{"event":"plan_applied","space":…,"revision":…,"count":…}` | each layout written |
| `{"event":"missing_space","n":…,"count":…}` | ⌥N for a Desktop that doesn't exist (`throw-no-space` expects it for ⌥⇧N too) |
| `{"event":"throw","n":…,"result":…}` | each ⌥⇧N attempt; `result` is `moved`, `alreadyThere`, `noSuchSpace`, `refusedFullscreen`, `noGrabPoint`, `timedOut`, `transitionInFlight`, `failed` or `noFocusedWindow` |
| `{"event":"floated","window":…,"reason":"fights"}` | a window floated after fighting its tile |
| `{"event":"stopped"}` | clean shutdown |

`SIGHUP` reloads the config. A bad config logs `config_error` and the app keeps running. `SIGTERM` and `SIGINT` quit cleanly with status 0.

### Scenarios
```
tile-1 tile-2 tile-3 tile-5 tile-8      exact layouts against the oracle
close-reflow reopen                      closing / reopening reflows
min-size min-size-accommodate min-size-unsatisfiable non-resizable-floats   size constraints
sheet-ignored panel-ignored dialog-ignored tabs-dedupe
minimize-restore hide-restore fullscreen-restore   windows return to their tile
hung-app-isolation snap-back-no-loop late-window   misbehaving apps
throw-to-space-2 throw-held-modifiers    throws (post ⌥⇧N; the second holds ⌥⇧ like a person)
throw-titlebar-variants                  transparent / tabbed / toolbar titlebars: moved or noGrabPoint
throw-no-space throw-already-there       noSuchSpace (+ missing_space), alreadyThere
throw-rapid                              two throws 150 ms apart: second never lost, cursor restored
missing-space-notice                     ⌥(count+1)
display-cache                            skipped: needs 2+ displays (manual check)
config-reload bad-config-survives        SIGHUP
```
Details of the newer ones:
- **`hung-app-isolation`:** while fixture A's main thread is blocked, fixture B's window must be tiled within 1 s, **and** a SIGHUP must come back as `config_loaded` within 500 ms. The second check proves hyprMac itself (menu bar, signal handling) isn't stuck behind the hung app.
- **`throw-titlebar-variants`:** for each variant the result must be `moved` (and the window fills Space 2) or a clean `noGrabPoint` (no Space switch, window untouched). Which one each variant got is printed as a TAP note, together with the titlebar roles the grab candidates hit.
- **Space restore:** every Space-switching scenario returns to the Desktop it started on in a `defer`, so a failure never strands you on another Desktop. The run as a whole also returns to the Desktop it started on.
`hyprmac-e2e --list` prints them with one-line descriptions.

### Checks that need no permissions
```sh
make swift-build
BIN=$(swift build --package-path macos -c release -Xlinker -L$PWD/build/release --show-bin-path)
$BIN/hyprmac-e2e --oracle-selftest    # oracle vs hand-computed layouts: 47/47
$BIN/hyprmac-e2e --fixture-selftest   # fixture windows, commands and titlebar variants: 21/21
```

### E2E runbook
The full run moves real windows and posts real keystrokes and modifier presses (⌥⇧N, ⌥N, held ⌥⇧). Run it when you can leave the Mac alone for a few minutes.

1. **Check the preconditions:**
   - **Stage Manager is off, for real.** `defaults read com.apple.WindowManager GloballyEnabled` must print `0`; otherwise the harness refuses to start (exit 2), and so would the app: it would log `paused`/`stage_manager`, which the harness also treats as a preflight failure. `make install` writes that setting, **but macOS keeps Stage Manager running until you toggle it off once in Control Center (or log out)**. Neither the harness nor hyprMac can see the live state, so check Control Center yourself before running.
   - **⌥1–⌥9 are bound** to "Switch to Desktop N" (System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control).
   - **At least 2 Desktops exist.** With fewer, the throw scenarios are skipped. With 3 or more, `throw-rapid` sends its second throw to Desktop 3.
   - **The terminal has Accessibility permission.** The app is launched as a child of the harness and inherits it. Without it, the harness prints instructions and exits 2.
2. **Quit the installed hyprMac** (menu ▸ Quit hyprMac). The harness refuses to run (exit 2) while any other app with bundle id `dev.codesmith28.hyprmac` is running, because two tilers would fight.
3. **Quit other window managers** such as Rectangle. The harness warns about them.
4. **Save your work.** By default the harness **hides every other app**, so that only fixture windows are tiled, and unhides them at the end. Ctrl-C also restores them. Use `--no-hide-others` to skip this; your windows will then be tiled too and layout checks may fail.
5. **Run the suite:**
   ```sh
   make test-e2e E2E_ARGS="--keep-going"
   ```
   Other forms:
   - one scenario: `make test-e2e E2E_ARGS="--scenario tile-2"`;
   - several: `--scenario a b` or `--scenario a,b`;
   - stop at the first failure: leave out `--keep-going`;
   - per-scenario time limit: `--timeout S` (default 60).
6. **Read the results:**
   - Output is TAP, ending with a `# summary:` line.
   - Exit status: 0 means everything passed or was skipped, 1 a scenario failed, 2 a preflight failure or bail-out.
   - Each scenario's files are in `$TMPDIR/hyprmac-e2e-<pid>/<scenario>/`: the config, `events.jsonl`, the app's stdout and stderr (`hyprmac.out.log`) and the fixture's stderr.
   - A failed layout prints an expected-vs-actual frame table and the last lines of the event log.
7. **Afterwards:** the harness returns to the Desktop you started on and re-activates the app that was in front. Start the installed hyprMac again if you want it back.

Known caveats:
- Some scenarios check behaviour that is still being fixed and fail until the fix is merged. The failure message names the gap:
  - **`throw-rapid`:** a ⌥⇧N pressed while a throw is in flight is currently dropped without any event.
  - **`throw-no-space`:** a throw to a missing Desktop posts the notice to Notification Center but logs no `missing_space` event.
  - **`hung-app-isolation`:** hung apps only stop stalling discovery once the process-wide Accessibility timeout fix lands.
- `minimize-restore` is skipped if macOS refuses to minimize the fixture window. That happened while Stage Manager was on.
- `tile-8`'s smallest tile is about 85 × 50 pt on a 1512 × 982 screen. That is close to AppKit's minimum window size, and the scenario prints a note when that is a factor.
