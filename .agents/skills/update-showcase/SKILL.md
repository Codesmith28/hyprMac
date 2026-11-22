---
name: update-showcase
description: >-
  Audits and synchronizes the hyprMac web showcase landing page (in web/)
  whenever features, shortcuts, configuration options, make targets, or
  system requirements are added, updated, or removed in the hyprMac codebase.
---

# Update Showcase Skill

Use this skill whenever features, shortcuts, configuration options, make targets, or requirements are added, modified, or removed in `hyprMac`. This skill ensures the project showcase website in `web/` always remains an exact, authentic reflection of the codebase.

## Core Rules & Guardrails
1. **Never Invent Features**: Only document and showcase capabilities explicitly supported by the hyprMac codebase.
2. **Pure System Monospace**: Maintain `font-family: monospace;` strictly across all styles. No external webfonts.
3. **Flat, Gradientless Palette**: Keep the Swiss-minimalist aesthetic (flat `#0e0e0e` background, crisp 1px neutral `#262626` borders, zero neon glow, zero box-shadow blurs).
4. **Vector SVG Animations**: Feature animations must be vector SVGs inspired directly by `macos/Sources/HyprApp/ShortcutIllustration.swift` with smooth CSS keyframes.
5. **Authentic Keycaps & Vector Assets**: Render shortcuts with `<kbd class="kbd">` keycaps (`⌥`, `⇧`, `⌘`, `1–9`, `H`, `J`, `K`, `L`, etc.). Never escape modifiers with backslashes. Always use vector `<svg class="apple-logo">` instead of Apple's private-use unicode glyph (``), which causes `[?]` missing glyph boxes on non-Apple operating systems.
6. **Realistic Resizing Dummy Apps**: Windows must render authentic dummy application UI components (`dummy-term` with shell prompts, `dummy-calc` with keypad grid and digital readout, and `dummy-finder` with sidebar and file hierarchy) that fluidly adapt when window tiles resize.
7. **Dual-Space Throwing Visualization**: Spaces throwing animations must show both `Desktop 1` and `Desktop 2` side-by-side (`.dual-spaces-workspace`) so the user visually sees the window moving across into Desktop 2 and the remaining window expanding.

---

## Step-by-Step Sync Workflow

### 1. Audit Codebase Sources of Truth
Inspect the authoritative sources in the repository:
- **Core capabilities & quickstart**: `README.md`
- **Shortcuts & tutorial illustrations**: `macos/Sources/HyprApp/CheatsheetCatalog.swift` and `macos/Sources/HyprApp/ShortcutIllustration.swift`
- **Configuration schema**: `docs/USAGE.md` and `config = { ... }` defaults
- **Terminal targets**: `Makefile`
- **Architecture & serial queues**: `docs/ARCHITECTURE.md` and `core/include/hypr/hypr_core.h`

### 2. Update `web/index.html`
- **Hero Section**:
  - Two-column split layout (`.hero-2col`):
    - **Left Column** (`.hero-left-col`): Platform metadata, official `square.split.2x2` icon + `<h1 class="hero-title">hyprMac</h1>`, tagline, architecture summary, and wrapped quickstart command (`git clone ... && make install`) with 1-click copy button.
    - **Right Column** (`.hero-right-col`): Full-size macOS desktop container (`.hero-desktop-preview`) displaying the continuous end-to-end user workflow animation with real-time OSD HUD notifications.
  - Keep `min-height: calc(100vh - 52px)` with the bouncing `explore features` button pinned at bottom center.
- **Alternating Feature Showcase**:
  - For new features: Add an alternating `.feature-row` (Desc Left/Anim Right $\leftrightarrow$ Anim Left/Desc Right).
  - For removed features: Delete the obsolete `.feature-row` and its corresponding CSS keyframe in `animations.css`.
  - Ensure every feature displays `<kbd class="kbd">` badges for its default keybindings.
- **Cheatsheet Table**:
  - Sync table rows with `CheatsheetCatalog.entries(for: keys)` from `macos/Sources/HyprApp/CheatsheetCatalog.swift`.
  - Format keys with `<kbd class="kbd">`.
- **Configuration Block**:
  - Ensure the Lua config block strictly displays the exact default `~/.config/hyprmac/init.lua` schema with proper indentation and line breaks inside `keys = { ... }`.
  - Maintain syntax highlighting tags (`.syn-key`, `.syn-prop`, `.syn-str`, `.syn-num`, `.syn-bool`, `.syn-comment`, `.syn-punct`).
- **Requirements & Make Targets**:
  - Render with bulleted lists (`<ul class="item-list">`).

### 3. Update `web/animations.css`
- If an animation changes or a new illustrated shortcut is added to `ShortcutIllustration.swift`:
  - Port the coordinate physics from SwiftUI `Canvas` to an SVG with `viewBox="0 0 352 224"`.
  - Base screen frame: `rect x="36" y="20" width="280" height="184" rx="12"`.
  - Animate elements using CSS `@keyframes` with `cubic-bezier(0.2, 0, 0.2, 1)`.

### 4. Verification Checklist
Run automated validation before concluding:
```bash
node -e '
const fs = require("fs");
const html = fs.readFileSync("web/index.html", "utf8");
const style = fs.readFileSync("web/style.css", "utf8");
const anim = fs.readFileSync("web/animations.css", "utf8");

// 1. Verify Hero & Brand Title
if (!html.includes("<h1 class=\"hero-title\">hyprMac</h1>")) throw new Error("Hero title missing");

// 2. Verify Install Command Text
const cmd = html.match(/id="install-cmd">([\s\S]*?)<\/code>/)[1].replace(/<[^>]+>/g, "").replace(/&amp;&amp;/g, "&&").trim();
if (cmd !== "git clone https://github.com/Codesmith28/hyprMac.git && cd hyprMac && make install") throw new Error("Install command mismatch");

// 3. Verify No Escaping Bugs
if (html.includes("\\1-\\9") || html.includes("\\⇧")) throw new Error("Found escaped keycap artifacts");

// 4. Verify Terminal Commands & Key Navigation
if (!html.includes("make</span> <span class=\"sh-sub\">update</span>")) throw new Error("make update target missing");
if (!html.includes("<kbd class=\"kbd\">H</kbd> / <kbd class=\"kbd\">J</kbd> / <kbd class=\"kbd\">K</kbd> / <kbd class=\"kbd\">L</kbd>")) throw new Error("H/J/K/L not separated with slashes");
if ((html.match(/arrow keys/gi) || []).length < 3) throw new Error("Arrow keys support not mentioned");

console.log("All showcase verification checks passed!");
'
```
