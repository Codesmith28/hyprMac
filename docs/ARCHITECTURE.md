# Architecture

hyprMac is a BSP tiler for macOS that works with native Spaces.

## Layers

```
HyprApp (Swift)           menu bar, onboarding, notifications
  └ HyprKit (Swift)       EventCoordinator: one serial queue, debounced
      ├ HyprPlatform      Accessibility, observers, Spaces, displays, hotkeys, executor
      └ CHyprCore         libhyprcore.a (C++20): BSP engine + Lua config
                          C API: core/include/hypr/hypr_core.h
```

The C++ core does the layout math and never touches Accessibility. HyprPlatform does the macOS work and never does layout. The C API in `core/include/hypr/hypr_core.h` is the boundary between them. Treat it as frozen.

## Data flow
1. A window event (open, move, minimize) schedules a reconcile.
2. Discovery snapshots each display's active Space.
3. The engine compares that with the Space's tree and returns a numbered plan of target frames.
4. The executor writes the frames through Accessibility, one queue per app, so a hung app only delays its own windows.

## Layout rules
- Each split satisfies `L1 + L2 + inner = L`.
- Dwindle insertion: the focused tile splits along its longer axis, and the new window goes second.
- The outer gap is applied once, to the usable rectangle. A single window fills that rectangle minus the outer gap.
- Each display and each native Space has its own tree.
- Fullscreen, minimized and hidden windows leave a ghost slot in the tree and return to it later.

## Throws (the drag trick)
1. Mouse-down on an empty titlebar spot.
2. Post the native ⌥N.
3. Wait for the Space to change.
4. Mouse-up, then put the cursor back.

Focus follows the window. Details and failure cases are in [limitations](LIMITATIONS.md#moving-windows-between-spaces).

## Coordinates
Everything in the core is in top-left-origin points, the convention Accessibility uses. HyprPlatform converts from NSScreen's bottom-left frames with `y_top = primaryScreenHeight - (frame.origin.y + frame.height)`.

## Build
- Only Command Line Tools are used, no Xcode. `swift test` needs the Swift Testing flags that `mk/swift.mk` passes, so always build through `make`.
- Swift targets use Swift 5 language mode to avoid strict-concurrency friction with C callbacks.
- `make test` needs no system permissions and doesn't touch the real system.
