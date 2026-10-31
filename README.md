# hyprMac

**Hyprland-style automatic tiling for macOS that keeps your native Spaces.**

hyprMac arranges your windows into a binary-space-partition layout as you open them. It works with the Desktops you already have in Mission Control: it doesn't replace them with virtual workspaces and doesn't need System Integrity Protection disabled.

It is also a learning project. The layout engine is C++20 with a C API, the macOS layer is Swift, the configuration is sandboxed Lua, and the install is fully reversible. The [architecture](#architecture) and [testing](docs/TESTING.md) sections show how the pieces fit together.

## Features
- **BSP tiling with dwindle insertion.** A new window splits the focused tile along its longer side (a square tile splits side by side) and takes the second half.
- **Gaps.** The inner gap (default 8 pt) goes between tiles and the outer gap (default 12 pt) between tiles and the screen edges. Every split satisfies `L1 + L2 + inner = L`, and the outer gap is applied once, to the usable area of the screen (menu bar and Dock excluded).
- **Native Spaces, native switching.** ⌥1–⌥9 stay the macOS "Switch to Desktop N" shortcuts. hyprMac only *listens* to them so it can tell you when Desktop N doesn't exist.
- **⌥⇧1–⌥⇧9 throw the focused window to Desktop N.** macOS has no public API for this, so hyprMac uses a "drag trick": it holds the window by its titlebar, switches Desktop, and lets go. The window lands on the new Desktop and keeps focus, as in Hyprland's `movetoworkspace`. See [LIMITATIONS](docs/LIMITATIONS.md#moving-windows-between-spaces).
- **Windows come back to the same spot.** A window that goes fullscreen, is minimized, or whose app is hidden (⌘H) leaves a placeholder in the layout. When it returns, it gets the same tile back.
- **Per-display tiling.** Each display is tiled from its own active Space, and each Space has its own layout.
- **Sensible floating.** Sheets, dialogs, panels, popovers and other non-standard windows are never tiled. Non-resizable windows, windows without a close button, Archive Utility and Calculator float. A window that keeps resizing itself away from its tile (3 times within 10 s) is floated instead of fought.

## Requirements
- **macOS 14 Sonoma or later.** Developed and tested on macOS 27.2, Apple silicon.
- **Command Line Tools for Xcode** (`xcode-select --install`). Xcode itself is not needed.
- **System Settings ▸ Desktop & Dock ▸ "Displays have separate Spaces": ON.** This is the macOS default.
- **Stage Manager off.** `make install` turns it off for you and `make uninstall` restores it. While it is on, hyprMac pauses itself.
- **"Switch to Desktop N" shortcuts on ⌥N.** Set them under System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control. `make install` adds ⌥8 and ⌥9 if they are unbound; set ⌥1–⌥7 yourself if they aren't already.

## Quick start
```sh
git clone <this repo> hyprMac && cd hyprMac
make            # build the C++ core and build/hyprMac.app
make test       # every test that needs no permissions (C++ core, Swift, install scripts)
make install    # install to ~/Applications and start at login; reversible
make uninstall  # undo everything make install did, then prove it
```

After `make install`, System Settings opens at **Privacy & Security ▸ Accessibility**. Turn hyprMac on there and tiling starts within a second; no restart needed.

To try it without installing, run `make run`. The app runs from `build/` in the foreground. It needs Accessibility permission, which it asks for on first launch.

## What `make install` changes, and how `make uninstall` reverts it
`make install` builds the app, then runs `scripts/install.sh`. Every change is first written to a manifest at `~/Library/Application Support/hyprMac/install/manifest`, together with what was there before. `make uninstall` (`scripts/uninstall.sh`) replays that manifest in reverse.

Before the first change, install takes a **snapshot** of everything it may touch (`before.snapshot`). After uninstalling, the current state is snapshotted again and compared; any difference is printed and uninstall exits with status 1.

| Step | `make install` does | `make uninstall` does |
|---|---|---|
| Snapshot | Fingerprints the hotkeys, Stage Manager, notification settings, LaunchAgent, LaunchServices, the app bundle, the config dir and the app's preference/cache files | Compares a fresh snapshot with it (`verify-rollback`) |
| State dir | Creates `~/Library/Application Support/hyprMac/install/` (manifest, backups, snapshot) | Deletes it, and only the parent directories install created |
| Existing app data | Backs up any hyprMac preferences, caches, saved state or notification settings that already exist | Puts the backups back |
| App | Copies `hyprMac.app` to `~/Applications/` (creating the folder if needed). An existing bundle there is moved aside first | Removes the bundle and restores the one moved aside |
| LaunchServices | `lsregister -f ~/Applications/hyprMac.app` | `lsregister -u` |
| Shortcuts | Adds symbolic hotkeys **125 (⌥8)** and **126 (⌥9)**, "Switch to Desktop 8/9", **only if they are absent**, then applies them with `activateSettings -u`. Existing bindings are never touched | Deletes only the entries it added, then applies again |
| Stage Manager | Records `com.apple.WindowManager GloballyEnabled` (value and type, or "absent") and writes `false` | Writes the recorded value back, or deletes the key if it was absent |
| Config | Creates `~/.config/hyprmac/init.lua` from `config/init.lua.example`, **only if the folder doesn't exist** | Deletes it (keep it with `KEEP_CONFIG=1 make uninstall`). A folder that existed before is never touched |
| Login item | Writes `~/Library/LaunchAgents/dev.codesmith28.hyprmac.plist` (RunAtLoad on, KeepAlive off) | Boots out and deletes it, restoring any plist moved aside |
| Accessibility | `tccutil reset Accessibility dev.codesmith28.hyprmac`, a clean slate for the new ad-hoc signature | Resets the entry again |
| Start | `launchctl bootstrap gui/$UID` starts hyprMac, then opens the Accessibility settings pane | Quits the app first |
| App residue | none | Removes hyprMac's preferences, caches, saved state, HTTP storage and its notification settings entry, unless they existed before install |

Notes:
- **Failed installs roll back.** If any step fails, everything done so far is rolled back.
- **Re-running install upgrades.** Running `make install` again when a manifest exists only replaces the app bundle and reloads the LaunchAgent; the recorded original values are kept.
- **Dry runs.** `scripts/install.sh --dry-run` and `scripts/uninstall.sh --dry-run` print every command without running it.
- **Uninstalling without the repo.** The app bundle carries a copy of the scripts, so you can uninstall with `~/Applications/hyprMac.app/Contents/Resources/scripts/uninstall.sh`.
- **Checking anytime.** `make verify-rollback` compares the live state with the pre-install snapshot.
- **Blind spots.** Some things a snapshot can't see; they're listed in [LIMITATIONS](docs/LIMITATIONS.md#what-verify-rollback-cannot-see).

## Configuration
hyprMac reads `~/.config/hyprmac/init.lua`. Every key is optional, and a missing file means defaults.

```lua
config = {
    gaps = {
        inner = 8,   -- points between adjacent windows      (0 – 200)
        outer = 12,  -- points between windows and the edges (0 – 200)
    },
    split_ratio = 0.5, -- share of a split given to the existing window (0.1 – 0.9)
}
```

- **Applying changes.** Reload after editing with the menu bar item ▸ **Reload Configuration**, or `pkill -HUP -x hyprMac`.
- **Errors.** A file with an error is rejected as a whole: hyprMac keeps the previous settings and shows a notification with the file, line and message.
- **The Lua sandbox.** The schema is strict: unknown keys and wrong types are errors. The Lua runs with only the `base`, `string`, `math` and `table` libraries, with no `io`, `os`, `require` or `load`, an 8 MB memory cap and an instruction limit, so a typo can't hang or harm anything.

## Architecture
```
                ┌───────────────────────────────────────────────────────────┐
  menu bar  ◀──▶│ HyprApp (Swift)   status item · onboarding · notifications │
                │                   SIGHUP = reload · SIGTERM = clean quit   │
                └──────────────────────────────┬────────────────────────────┘
                                               │ TilingController
                ┌──────────────────────────────▼────────────────────────────┐
                │ HyprKit (Swift)   Coordinator: one serial queue            │
  AX events ───▶│   events ─▶ debounce ─▶ snapshot ─▶ engine ─▶ executor     │
  ⌥N / ⌥⇧N  ───▶│   fight detection · Stage Manager / permission checks      │
                └───────┬───────────────────────────────────────┬──────────┘
                        │                                       │ C API (hypr_core.h)
  ┌─────────────────────▼─────────────────────┐   ┌─────────────▼────────────────────┐
  │ HyprPlatform (Swift)                      │   │ libhyprcore.a (C++20)            │
  │  AX backend · observers · eligibility     │   │  BSP layout tree per Space       │
  │  window discovery · per-app executor      │   │  dwindle insertion · ghost slots │
  │  SkyLight Spaces (read-only, dlsym)       │   │  gap & min-size geometry         │
  │  Carbon hotkeys ⌥⇧N · listen-only tap ⌥N  │   │  sandboxed Lua 5.4 config        │
  │  SpaceMover (drag trick)                  │   │                                  │
  │  FakeAX simulator for tests               │   │                                  │
  └───────────────────────────────────────────┘   └──────────────────────────────────┘
```

- **Data flow.** A window event, such as one opening, moving or minimizing, schedules a reconcile. Discovery snapshots each display's active Space, the C++ engine compares it with that Space's tree and returns a numbered plan of target frames, and the executor writes them through Accessibility on one queue per app, so a hung app can't stall the others.
- **Coordinates.** Everything is in top-left-origin points, the Accessibility convention.
- **Further reading.** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the design reference. [docs/QUIRKS.md](docs/QUIRKS.md) records the macOS behaviour that was verified on a real machine before it was relied on.

## How it compares
The central trade-off for a macOS tiler is what to do about Spaces, because Apple provides no public API to create Spaces or move windows between them.

| | Spaces model | Needs SIP changes? | Trade-off |
|---|---|---|---|
| **yabai** | Native Spaces, fully scripted: create, destroy, focus, move windows | Yes, for the Space features: partly disabling SIP to load its scripting addition into the Dock | The most control, but you weaken system security and depend on private internals that change between macOS releases |
| **Amethyst** | Native Spaces | No | Several fixed layouts (tall, wide, BSP and more). Moving a window to another Space uses a mouse-drag trick |
| **AeroSpace** | Its own virtual workspaces; macOS Spaces are not used | No | Fast, i3-like and very predictable. Hidden workspaces are emulated by parking windows off-screen, so Mission Control and swipe gestures don't match your workspaces |
| **hyprMac** | Native Spaces | No | Hyprland-style dwindle tiling on the Spaces you already use. It can't create or delete Spaces, and throwing a window takes about half a second and needs a grabbable titlebar |

## Make targets
`make help` lists them:

| Target | What it does |
|---|---|
| `make` / `make build` | build everything (core + `hyprMac.app`) |
| `make core` | build `libhyprcore.a` (C++ core + Lua) |
| `make app` | assemble and ad-hoc sign `build/hyprMac.app` |
| `make run` | run the app from `build/` (foreground, logs to terminal) |
| `make swift-build` | build all Swift products |
| `make test` | all tests that need no permissions (`core-test`, `swift-test`, `scripts-test`) |
| `make core-test` | run the C++ core and config tests |
| `make test-asan` | run the core tests under AddressSanitizer and UBSan |
| `make swift-test` | run the Swift Testing suites (FakeAX, coordinator) |
| `make scripts-test` | sandboxed tests for install/uninstall (fake HOME + command shims) |
| `make install` | install to `~/Applications` with recorded, reversible system changes |
| `make uninstall` | reverse every recorded install action, then verify the rollback |
| `make verify-rollback` | diff the current state against the pre-install snapshot |
| `make clean` | remove build products (never touches the system) |

`make test-e2e` runs the real-macOS end-to-end suite. It needs Accessibility permission and a quiet desktop; see [docs/TESTING.md](docs/TESTING.md). It works, but `make help` doesn't list it because the help pattern skips target names that contain a digit.

## Documentation
- [docs/USAGE.md](docs/USAGE.md): shortcuts, the menu, notifications, reloading, troubleshooting
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md): what macOS makes impossible or fragile, and how hyprMac copes
- [docs/TESTING.md](docs/TESTING.md): the test pyramid and the end-to-end runbook
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/QUIRKS.md](docs/QUIRKS.md): design reference and verified macOS behaviour
