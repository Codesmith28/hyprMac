# hyprMac architecture

hyprMac is a Hyprland-style BSP tiler for macOS that works with **native** Spaces.

## Features
- Windows tile automatically in a BSP layout. New windows use dwindle insertion: the focused tile is split along its longer axis and the new window goes second.
- Gaps are configurable (inner 8, outer 12 by default) through an optional `~/.config/hyprmac/init.lua`.
- ⌥1–9 switch Spaces using the **native** macOS "Switch to Desktop N" shortcuts.
  - hyprMac only listens to these keys. When the requested Space doesn't exist, it shows a notification.
- ⌥⇧1–9 throw the focused window to Space N with the "drag trick":
  1. Post a synthetic mouse-down on an empty titlebar spot.
  2. Post the native ⌥N.
  3. Wait for the Space change.
  4. Post mouse-up and restore the cursor.

  Focus follows the window.
- Fullscreen, minimized and hidden windows are removed from the tree into a **ghost slot** and return to the same position later.
- Each display is tiled independently, and each native Space has its own tree.

## Layers
```
HyprApp (Swift, menu bar, onboarding, notifications)
  └─ HyprKit (Swift): EventCoordinator — single serial queue, debounced
        ├─ HyprPlatform (Swift): AX, observers, spaces, displays, hotkeys, executor, SpaceMover
        └─ CHyprCore → libhyprcore.a (C++20): BSP engine + Lua config  [C API: core/include/hypr/hypr_core.h]
```

## Coordinates
Everything inside the core uses top-left-origin logical points, which is the convention the Accessibility API uses. HyprPlatform converts from NSScreen's bottom-left frames: `y_top = primaryScreenHeight - (frame.origin.y + frame.height)`.

## Gap rule
- Each split satisfies `L1 + L2 + inner_gap = L`.
- The outer gap is applied once, to the root (usable) rectangle.
- With a single window, the window fills the usable rectangle minus the outer gap.

## Ownership (Phase 1 workstreams; touch only your paths)

| Workstream | Branch | Owns |
|---|---|---|
| A core | `feat/core` | `core/include/hypr/*.hpp` (except `config.hpp`), `core/src/*` (except `config*.cpp`), `core/tests/*` (except `config_*`), deletes `core/src/c_api_stub_phase0.cpp` |
| B config+install | `feat/install` | `core/src/config_lua.cpp`, `core/tests/config_*`, `scripts/**`, `mk/install.mk`, `config/` |
| C platform | `feat/platform` | `macos/Sources/HyprPlatform/**`, `macos/Tests/HyprPlatformTests/**` |
| D fixture+e2e | `feat/e2e` | `macos/Sources/FixtureApp/**`, `macos/Sources/HyprE2E/**` |
| integration | `main` | `macos/Sources/HyprKit/**`, `macos/Sources/HyprApp/**`, `Makefile`, `mk/swift.mk`, `macos/Package.swift` |

Frozen contract: `core/include/hypr/hypr_core.h`. If a workstream thinks it needs a change, it records the request in its final report and does not edit the file.

## Build facts
- There is no Xcode, only Command Line Tools. `swift test` therefore needs the explicit Swift Testing plugin and framework flags, which `mk/swift.mk` already passes. Always go through `make`.
- Swift targets use Swift 5 language mode (`.swiftLanguageMode(.v5)`) to avoid strict-concurrency friction with C callbacks.
- `make test` runs `core-test`, `swift-test` and `scripts-test`. None of them need system permissions.
