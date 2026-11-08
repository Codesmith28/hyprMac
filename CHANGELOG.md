# Changelog

All notable changes to hyprMac will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.2.0] - 2026-11-08

### 🚀 Added
- 🧭 **Native Navigation**: Directional focus (`⌥⇧H/J/K/L`, `⌥⇧Arrows`) and window swap (`⌥⇧⌘H/J/K/L`, `⌥⇧⌘Arrows`).
- ⌨️ **Configurable Keybindings**: Expose all navigation, prefix, and action keys in `init.lua`.
- 🎯 **Center Window**: `⌥⇧C` shortcut to center active window on current display.
- 🖱️ **Cursor Warp**: Auto-center cursor onto newly focused windows.
- 🪟 **Drag-to-Swap**: Drag and drop tiled windows onto neighbors to swap layout slots.
- 💾 **State Persistence**: Retain tiled/floating states and exact window dimensions across app relaunch.
- 🔔 **OSD HUD Notifications**: Native AppKit overlay for window states, workspace switches, and throws.
- 🎛️ **OSD Configuration**: Toggle HUD notifications via `osd_popup` flag in `init.lua`.
- 📋 **Window Rules**: Configurable `rules.float` and `rules.ignore` app filtering lists.
- ⚡ **`make update` Command**: Rebuild, reinstall, and restart background daemon in one step.

### 🐛 Fixed
- ⚡ **Faster Space Throws**: Reduced transition delays by ~60% for snappier workspace throws.
- 🚦 **Window Throw Reliability**: Dynamic traffic-light gap detection & micro drag-delta fix moving complex windows (Chrome, Arc, Safari, Teams) across spaces (⌥⇧1..9).
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
