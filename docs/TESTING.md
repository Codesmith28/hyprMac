# Testing hyprMac

The tiler's input is the live desktop and its output is other apps' windows, so it's hard to test directly. Most of hyprMac runs without a desktop. The part that can't is tested by an end-to-end harness on a real Mac.

```
                  real Mac, needs Accessibility, minutes
            ┌───────────────────────────────────────────┐
            │ E2E: hyprmac-e2e + fixture app, 23 scenes │
            ├───────────────────────────────────────────┤
            │ install scripts in a fake HOME            │
            ├───────────────────────────────────────────┤
            │ Swift + FakeAX simulated desktop          │
            ├───────────────────────────────────────────┤
            │ property tests: 10,000 random steps       │
            ├───────────────────────────────────────────┤
            │ C++ unit tests (doctest)                  │
            └───────────────────────────────────────────┘
                  no permissions, seconds
```

`make test` runs the bottom four layers. CI (`.github/workflows/ci.yml`) runs `make test` and `make test-asan` on every push and PR; the e2e layer never runs there. None of them needs a permission or touches the real system.

## 1. C++ core (doctest)
`make core-test` runs `core/tests/*` with [doctest](https://github.com/doctest/doctest), vendored in the repo. It covers the layout tree, BSP geometry, geometry helpers, the engine (reconcile, ghost slots, multiple Spaces), the workspace model, the C API, and config validation and the Lua loader.

The Lua loader tests check:
- syntax and runtime errors report the file and line;
- NaN and out-of-range values;
- unknown keys, with "did you mean" hints;
- binary chunks and files over 256 KB;
- infinite loops, including ones hidden behind `pcall` or `__close`;
- memory bombs (the 8 MB cap);
- attempts to reach `io`, `os`, `require`, `load` or `debug`.

`make test-asan` runs the same tests under AddressSanitizer and UBSan.

## 2. Property tests
`core/tests/property_tests.cpp` builds a simulated world of windows on three Spaces and mutates it for 10,000 steps. It opens and closes windows, changes their state (minimized, hidden, fullscreen, floating), moves them between Spaces, adds minimum-size hints and switches configs.

After each step it checks that the tree's invariants hold, the tiled leaves match the world's tiled windows, plan revisions only increase, the plan matches the layout, and tile and gap areas add up to the usable area. A second test runs the same walk through the C API and checks for leaked nodes.

## 3. Swift and FakeAX
`make swift-test` runs the Swift Testing suites in `macos/Tests/`. The platform layer only talks to macOS through protocols (`AXBackend`, `SpaceProvider`, `DisplayProvider`, …). `HyprPlatform/Fakes/FakeDesktop.swift` implements them as an in-memory desktop.

Fake windows can have the quirks hyprMac has to survive:
- `minSize`, and `exposesMinSize` for the rare app that reports it;
- `clampToDisplay`, for apps that need size → position → size;
- `notReadyCalls`, where the first K Accessibility calls fail;
- `closesOnWrite`, a window that disappears mid-write;
- `snapsBack`, an app that reverts its own size;
- `titlebarRegions`, tabs and buttons under the titlebar that the drag trick must avoid.

**Coordinator tests** (`macos/Tests/HyprKitTests/`) run the real coordinator and C++ engine against the same fake desktop. They cover exact layouts and reflow, ghosts returning to their rectangle, per-Space trees and two displays, min-size relayout, floating after 3 fights, echo filtering, a hung app not blocking another, every throw result, Stage Manager, Rectangle, lost permission, config reload, and re-entrancy.

## 4. Install scripts in a sandbox
`make scripts-test` runs `scripts/tests/run.sh`. Each scenario gets a fresh fake `HOME` and a fake `hyprMac.app`. Every system command goes through a variable (`DEFAULTS`, `LAUNCHCTL`, `TCCUTIL`, `LSREGISTER`, …), and the tests point each one at a shim in `scripts/tests/shims/`.

A guard (`HYPR_SANDBOX=1`) refuses to run if any command points at a real system path, or if `HOME` is the real home.

The scenarios cover a clean install and uninstall with zero snapshot diff, upgrades, a failure injected at **every** install step (each must roll back), existing ⌥8/⌥9 bindings, pre-existing config and app data, Stage Manager on and off, notification settings, dry runs, uninstalling from inside the bundle, `verify-rollback` catching a deliberate change, and the opt-in signing identity (`make sign-identity`, with shimmed `security`, `codesign` and `openssl`, never the real keychain). `scripts/tests/release.sh` covers the release-notes and Homebrew cask helpers.

## 5. End-to-end on a real Mac
Two extra executables are built with the app:
- **`hyprmac-fixture`** is a small scriptable AppKit app. Flags control its windows: count, minimum size, non-resizable, native tabs, sheets, panels, dialogs, snapping back, slow resizes, late opening, hanging, fullscreen and titlebar style (`--titlebar standard|transparent|tabs|toolbar`). It reads commands on stdin (`open`, `close i`, `minimize i`, `fullscreen i`, `hide`, `focus i`, `quit`) and reports each action as JSON lines.
- **`hyprmac-e2e`** launches the real `hyprMac.app` and a fixture for each scenario. It reads the real frames through Accessibility, checks them against `CGWindowList`, and compares them with a **geometry oracle**: an independent Swift dwindle implementation that shares no code with the C++ engine. Frames must match within ±1 pt after 300 ms of stillness.

### Event log contract
The harness launches `hyprMac.app/Contents/MacOS/hyprMac --config <file> --event-log <file>`. The app appends one JSON object per line:

| Event | When |
|---|---|
| `started` | at launch |
| `config_loaded` / `config_error` | after every config load, including reloads |
| `paused` | with `reason` `stage_manager`, `accessibility` or `user` |
| `plan_applied` | each layout written (`space`, `revision`, `count`) |
| `missing_space` | ⌥N for a Desktop that doesn't exist |
| `throw` | each ⌥⇧N attempt, with `result` (`moved`, `alreadyThere`, `noSuchSpace`, `refusedFullscreen`, `noGrabPoint`, `timedOut`, `transitionInFlight`, `failed`, `noFocusedWindow`) |
| `floated` | with `reason` `fights` or `small` |
| `stopped` | clean shutdown |

`SIGHUP` reloads the config. A bad config logs `config_error` and the app keeps running. `SIGTERM` and `SIGINT` quit with status 0.

### Scenarios
```
tile-1 tile-2 tile-3 tile-5 tile-8         exact layouts against the oracle
close-reflow reopen                        closing and reopening reflows
min-size min-size-accommodate min-size-unsatisfiable
non-resizable-floats float-small           size constraints
sheet-ignored panel-ignored dialog-ignored tabs-dedupe
minimize-restore hide-restore fullscreen-restore
hung-app-isolation snap-back-no-loop late-window
user-resize                                a real drag on an edge (+200, then −150)
throw-to-space-2 throw-held-modifiers
throw-titlebar-variants                    transparent, tabbed and toolbar titlebars
throw-no-space throw-already-there
throw-rapid                                two throws 150 ms apart
missing-space-notice
display-cache                              needs 2+ displays (manual)
config-reload bad-config-survives
custom-keys                                toggle_float = ctrl+alt+t
```

Each scenario's config ignores the frontmost app at start, so the terminal running the tests is never tiled. Every Space-switching scenario returns to its starting Desktop in a `defer`, and the whole run does too.

`hyprmac-e2e --list` prints them with a one-line description.

### Checks that need no permissions
```sh
make swift-build
BIN=$(swift build --package-path macos -c release -Xlinker -L$PWD/build/release --show-bin-path)
$BIN/hyprmac-e2e --oracle-selftest    # oracle vs hand-computed layouts: 47/47
$BIN/hyprmac-e2e --fixture-selftest   # fixture windows, commands, titlebar variants: 21/21
```

### E2E runbook
The full run moves real windows and posts real keystrokes, so leave the Mac alone for a few minutes.

1. **Check the preconditions.**
   - Stage Manager is off for real. `defaults read com.apple.WindowManager GloballyEnabled` must print `0`. The install writes it, but macOS keeps Stage Manager running until you toggle it in Control Center or log out. Check Control Center yourself. The harness exits 2 otherwise.
   - ⌥1–⌥9 are bound to "Switch to Desktop N".
   - At least 2 Desktops exist. With fewer, the throw scenarios are skipped. With 3 or more, `throw-rapid` throws to Desktop 3.
   - The terminal has Accessibility. The app inherits it. Without it, the harness prints instructions and exits 2.
2. **Quit the installed hyprMac.** The harness refuses to run while another `dev.codesmith28.hyprmac` is running.
3. **Quit other window managers** such as Rectangle. The harness warns about them.
4. **Save your work.** By default the harness hides every other app so only fixture windows get tiled, and it unhides them at the end. Ctrl-C restores them too. `--no-hide-others` skips this, but then your own windows get tiled and layout checks may fail.
5. **Run it:**
   ```sh
   make test-e2e E2E_ARGS="--keep-going"
   ```
   - One scenario: `--scenario tile-2`. Several: `--scenario a b` or `--scenario a,b`.
   - Stop at the first failure: leave out `--keep-going`.
   - Time limit per scenario: `--timeout S` (default 60).
6. **Read the results.** Output is TAP, ending in `# summary:`. Exit 0 means everything passed or was skipped, 1 means a scenario failed, and 2 means a preflight failure. Each scenario's files are in `$TMPDIR/hyprmac-e2e-<pid>/<scenario>/`: the config, `events.jsonl`, `hyprmac.out.log`, and the fixture's stderr. A failed layout prints an expected-versus-actual table.
7. **Afterwards**, the harness returns to your starting Desktop and re-activates the app that was in front. Start the installed hyprMac again if you want it back.

Known caveats:
- Some scenarios check behaviour that isn't fixed yet, and they fail until it is. The failure message says what's missing:
  - `throw-rapid`: a ⌥⇧N pressed mid-throw is dropped without any event.
  - `throw-no-space`: the notice shows, but no `missing_space` event is logged.
  - `hung-app-isolation`: hung apps only stop stalling discovery once the process-wide Accessibility timeout fix lands.
- `minimize-restore` is skipped if macOS won't minimize the fixture. That happened with Stage Manager on.
- `tile-8`'s smallest tile is about 85 × 50 pt on a 1512 × 982 screen, close to AppKit's minimum window size. The scenario prints a note when that matters.
