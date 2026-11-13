# Changelog

All notable changes to hyprMac will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.3.0] - 2026-11-13

### 🚀 Added
- ↔️ **Split Direction**: ⇧-drop a tile on another's edge to re-split side by side or stacked, or use **Flip Split** in the menu.
- ⌨️ **Keyboard Actions**: Resize, equalize, rotate split, zoom, move to display and pause hotkeys, all unbound by default.
- 🛡️ **Shortcut Conflict Check**: Chords that clash with an enabled macOS shortcut are skipped and reported.
- 📋 **Rules & Gaps**: Title-based float/ignore rules, `smart_gaps`, per-display gaps, optional focus-follows-mouse, experimental pin-app-to-Desktop.
- 🔄 **Config Tools**: Auto-reload on save and `hyprMac --check-config`.
- 💻 **`hyprmacctl`**: CLI for status, retile, pause, resume and reload.
- 🎛️ **Menu**: Status, Launch at Login, OSD toggle, Reveal Configuration and Copy Log Command; pause is remembered.
- 🔑 **Stable Signing**: Opt-in `make sign-identity` keeps the Accessibility grant across upgrades.
- 📦 **CI & Release**: GitHub Actions, tag-driven releases and a Homebrew cask template.
- 🎞️ **Shortcut Cheatsheet**: Minimal modal with a looping animation per shortcut, opened with `⌥⇧/` or from the menu and closed with `Esc`.

### 🔄 Changed
- 🧹 **Menu Shortcuts**: Removed the ⌘, ⌘R and ⌘Q hints, which could never fire.
- ⌨️ **Shortcuts Dialog**: Now the animated cheatsheet, built from your live config.
- 🔔 **Notices**: Clicking one opens the right Settings pane; missing-Desktop and throw errors show in the OSD; warns when "Displays have separate Spaces" is off.
- 📖 **Docs**: Corrected the shortcut table and documented every config key.

### 🐛 Fixed
- 🎨 **OSD Border**: Corner radius now matches the block, with no gap.
- ⌨️ **Arrow Keys**: Stay bound when `focus_*` / `move_*` are set to letter keys, so H/J/K/L and ←/↓/↑/→ both work.

---

## [0.2.2] - 2026-11-10

### 🐛 Fixed
- 🛡️ **Single-Instance Enforcement**: Prevent duplicate instances from starting simultaneously on login (e.g. LaunchAgent + Login Items) using atomic kernel file locking (`flock`) and LaunchServices checks.

---

## [0.2.1] - 2026-11-10

### 🐛 Fixed
- 🪟 **Custom-Titlebar Throw**: Added 12 pt drag excursion and 40 ms press delay allowing GPUI, Electron, and custom-titlebar apps (e.g. Herdr) to reliably throw across Desktops.
- 👆 **Gesture Protection & Recovery**: Added automatic mouse-up fail-safe and space-arrival verification in `SpaceMover` to prevent WindowServer drag desyncs and protect native trackpad swipe gestures.
- 📦 **Lua Dependency Build**: Fixed `mk/deps.mk` to check both `.fetched` and `lua.h`, preventing missing `lua.hpp` errors on `make update` / `make install`.

---

## [0.2.0] - 2026-11-08

### 🚀 Added
- 🧭 **Native Navigation**: Directional focus (`⌥⇧H/J/K/L`, `⌥⇧Arrows`) and window swap (`⌥⇧⌘H/J/K/L`, `⌥⇧⌘Arrows`).
- ⌨️ **Configurable Keybindings**: Expose all navigation, prefix, and action keys in `init.lua`.
- 📐 **Spatial Initial Tiling**: Preserve physical on-screen arrangement (left-to-right, top-to-bottom) of pre-existing windows on startup.
- 🎯 **Center Window**: `⌥⇧C` shortcut to center active window on current display.
- 🖱️ **Cursor Warp**: Auto-center cursor onto newly focused windows.
- 🪟 **Drag-to-Swap**: Drag and drop tiled windows onto neighbors to swap layout slots.
- 💾 **State Persistence**: Retain tiled/floating states and exact window dimensions across app relaunch.
- 🔔 **OSD HUD Notifications**: Native AppKit overlay for window states, window centering, workspace switches, and directional throws.
- 🎛️ **OSD Configuration**: Toggle HUD notifications via `osd_popup` flag in `init.lua`.
- 📋 **Window Rules**: Configurable `rules.float` and `rules.ignore` app filtering lists.
- ⚡ **`make update` Command**: Rebuild, reinstall, and restart background daemon in one step.

### 🐛 Fixed
- ⚡ **Faster Space Throws**: Reduced transition delays by ~60% for snappier workspace throws.
- 🚦 **Window Throw Reliability**: Dynamic traffic-light gap detection & micro drag-delta fix moving complex windows (Chrome, Arc, Safari, Teams) across spaces (⌥⇧1..9).
- 🎯 **Preserve Dimensions on Center**: Centering an already-floating window (`⌥⇧C`) preserves its exact width and height without distorting responsive apps (LocalSend).
- 🎨 **OSD Visual & Timing Polish**: Synchronous instant updates, dynamic fit-content sizing, and 9-slice capsule masks eliminating sharp corner artifacts.
- 🖱️ **Ghost Click Bug**: Guaranteed cursor release across grab and target positions via `defer`.
- 🔍 **Electron Window Focus**: Fixed focus activation for apps with read-only AX focus (e.g. Obsidian).
- 👆 **Gesture Protection**: Require direct on-tile drops for window swaps to prevent native trackpad space swipes from being hijacked.
- 🍏 **macOS 14 Modernization**: Replaced deprecated `activateIgnoringOtherApps` API.

### 🧹 Maintenance
- 📦 **Lua Unvendoring**: Removed ~28.7k lines of tracked C code; fetch & verify via SHA256 at build time.
- 🩺 **LuaLS Diagnostics**: Suppressed `lowercase-global` warnings in user configuration.

---

## 📋 Changelog Template (For Future Releases)

<!-- Use the template below for each new release -->
<!-- Rules: Keep explanations to one concise line, use 1 emoji per category, avoid redundant details -->

```markdown
## [X.Y.Z] - YYYY-MM-DD

### 🚀 Added
- **Feature Name**: One-line explanation of the new capability.

### 🔄 Changed
- **Component**: One-line explanation of what changed and why.

### 🐛 Fixed
- **Bug Fix**: One-line explanation of the issue resolved.

### 🧹 Maintenance
- **Refactor / Cleanup**: One-line explanation of chore or internal update.
```
