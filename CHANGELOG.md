# Changelog

All notable changes to hyprMac will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.2.0] - 2026-11-06

### 🚀 Added
- **Native Keybindings**: Focus (`⌥⇧H/J/K/L`, `⌥⇧←/↓/↑/→`) and move/swap (`⌥⇧⌘H/J/K/L`, `⌥⇧⌘←/↓/↑/→`) with Vim & Arrow keys.
- **Configurable Keybindings**: Expose all navigation, prefix, and window keys in `init.lua` for full transparency and native compatibility.
- **Center Window**: `⌥⇧C` centers the focused window on its active display.
- **Warp Cursor on Focus**: Automatically moves mouse pointer to the center of the newly focused window.
- **Drag-to-Swap**: Dragging a tiled window onto a neighboring tile swaps their layout slots.
- **State & Dimension Persistence**: Remembers floating/tiled states and exact window dimensions across app relaunch.
- **Default Floating Apps**: Auto-floats System Settings, Docker Desktop, and MongoDB Compass.
- **`make update` Target**: Single command to recompile, install, and restart background service.

### 🐛 Fixed
- **Snappy Space Throw**: Reduced routine delay buffers by ~60% (press delay, shift release, and post-switch settle).
- **Browser & Electron Space Throw**: Added micro drag-delta to reliably throw Chrome, Brave, Arc, and Safari windows via `⌥⇧1..9`.
- **Dynamic Traffic Light Gaps**: Replaced hardcoded titlebar coordinates with runtime AX button midpoint geometry.
- **Ghost Click Elimination**: Guaranteed mouse button release on both grab point and current cursor position via `defer`.
- **Electron Focus Activation**: Added `AXRaise` and `NSRunningApplication.activate` for apps with read-only focus attributes (Obsidian).
- **Trackpad Workspace Gestures**: Restricted tile-swap to on-tile drops, preventing native screen-edge space drags from hijacking.
- **macOS 14 Deprecation Warnings**: Replaced deprecated `activateIgnoringOtherApps` with modern activation APIs.

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
