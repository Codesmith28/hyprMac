# Using hyprMac

hyprMac lives in the menu bar (the 2×2 grid icon). It has no Dock icon. After `make install` it starts at login.

## Shortcuts

| Keys | Action |
|---|---|
| ⌥1 … ⌥9 | Switch to Desktop N. macOS does this. hyprMac only listens, to warn you when Desktop N doesn't exist. |
| ⌥⇧1 … ⌥⇧9 | Move the focused window to Desktop N. You follow it, and it keeps focus. |
| ⌥⇧F | Float or tile the focused window. Floating restores the size hyprMac first saw, centred. The choice sticks until you toggle again or close the window. Fullscreen windows are ignored. |
| ⌥⇧C | Center the focused window. If tiled, floats and centers it at its original size. |
| ⌥⇧H / J / K / L or ⌥⇧← / ↓ / ↑ / → | Move focus in the BSP tree (left, down, up, right). |
| ⌥⇧⌘H / J / K / L or ⌥⇧⌘← / ↓ / ↑ / → | Move/swap the focused window in the BSP tree (left, down, up, right). Focus follows the moved window. |
| ⌥⇧/ | Open the shortcuts cheatsheet. Press it again, or Esc, to close. Works even while tiling is paused. Not configurable. |
| *unbound* `resize_left` / `down` / `up` / `right` | Move the nearest split boundary that way by `resize_step` percent. |
| *unbound* `equalize` | Reset every split in this Space to `split_ratio`. |
| *unbound* `rotate_split` | Flip the focused tile's split between side by side and stacked. |
| *unbound* `toggle_zoom` | The focused window fills the Space (outer gap kept); press again to restore the tiles. Ends when it closes, another tile gets focus or a window joins. |
| *unbound* `move_display_next` / `prev` | Move the focused window to the next / previous display (left to right, wrapping), into that display's current Space. |
| *unbound* `toggle_pause` | Pause or resume tiling, like the menu item. |

These are the built-in defaults. The rows marked *unbound* have no shortcut until you set one under `keys`; `config/init.lua.example` has suggested ⌥⇧ bindings. You can change them under [keys](#keys-and-app-rules). The example config lists the H/J/K/L keys explicitly, so arrow keys only work if you leave the `focus_*` / `move_*` keys out. The menu's **Keyboard Shortcuts…** (or ⌥⇧/) opens an animated cheatsheet of your active shortcuts.

New windows split the focused window along its longer side and take the second half. Close, minimize, hide or fullscreen a window and the rest reflow. When it comes back, it gets its old tile.

### Resizing by hand
Drag a tiled window's edge and let go. hyprMac keeps the new size.

- The split next to that edge moves with it, and the neighbours reflow. The new ratio sticks for later layouts.
- Ratios stay between 10 % and 90 %, and within the windows' minimum sizes.
- An edge on the screen boundary, or a window with no split on that axis, snaps back.
- Dragging a tiled window by its titlebar and dropping it onto another tile swaps the two tiles in the tree.
- Holding **⇧** when you let go re-splits instead of swapping. The window lands on the side of the tile under the cursor (left, right, top or bottom), so dropping one of two side-by-side windows on the bottom of the other stacks them, and dropping it on a side puts them side by side again. The middle of a tile still swaps.
- Dragging a floating window keeps its new position without snapping back.
- Moving a tiled window within its own tile snaps it back.
- A window that resizes itself, without the mouse, still counts as a fight.

The log line is `{"event":"user_resize",...}`.

## Menu

| Item | What it does |
|---|---|
| **Pause Tiling** / **Resume Tiling** | Stops or restarts tiling. While paused, windows stay where they are, and the icon is dimmed and changes to a pause symbol. Remembered across launches. |
| **Flip Split of Focused Window** | Flips the focused tile's split between side by side and stacked, same as `rotate_split`, with no shortcut needed. |
| **Retile All Windows** | Lays out every Space again. Also gives back windows that were floated for fighting their tile. |
| **OSD Popups** | Checkmark toggle for the small on-screen popups. Remembered in `~/.config/hyprmac/state.json`; until you use it, `osd_popup` in the config decides. |
| **Launch at Login** | Checkmark toggle. Enabled only when `make install` created the login item. Uses `launchctl enable/disable`. |
| **Open Configuration…** | Opens `~/.config/hyprmac/init.lua`, creating it from the example if needed. |
| **Reveal Configuration in Finder** | Shows the config file in Finder. |
| **Reload Configuration** | Re-reads the config and re-lays out. |
| **Keyboard Shortcuts…** | Opens the cheatsheet (also ⌥⇧/): your current shortcuts with a short animation each, including any you changed under `keys`. Esc closes it. |
| **Copy Log Command** | Copies a `log stream` command that shows hyprMac's log. |
| **Status** | ✓/✗ for Accessibility, Input Monitoring, Stage Manager off, and `keys.switch` matching a macOS Desktop shortcut. |
| **Grant Input Monitoring…** | Shown only while Input Monitoring is missing. Asks for it and opens the pane. |
| **Quit hyprMac** | Quits. Windows stay put. With the login item installed, hyprMac starts again at your next login. |

The popup for a window action appears on the display of the window you acted on. Menu items have no keyboard shortcuts.

## Notifications
hyprMac asks to show notifications the first time it runs. If you say no, the same messages still go to the log. Clicking a notification opens the relevant place: the Accessibility or Keyboard Shortcuts pane, or `init.lua` for configuration problems. With OSD popups on, the **Desktop N doesn't exist** and **Couldn't move window** notices show as a popup instead.

| Notification | What it means |
|---|---|
| **Desktop N doesn't exist** | You pressed ⌥N or ⌥⇧N for a Desktop you don't have. Add one in Mission Control. |
| **Couldn't move window to Desktop N** | The throw failed. The body says why: no titlebar spot to grab, fullscreen window, macOS didn't switch in time, or an Accessibility error. See [limitations](LIMITATIONS.md#moving-windows-between-spaces). |
| **Configuration error — kept previous settings** | `init.lua` didn't load. The body has `file:line: message`. |
| **Tiling paused: Stage Manager is on** | Turn Stage Manager off. Tiling resumes by itself. Right after install this shows until you toggle Stage Manager once or log out. |
| **Some shortcuts are unavailable** | Another app already owns one of your configured shortcuts. Change it under `keys`. |
| **Desktop switch shortcut mismatch** | `keys.switch` doesn't match any enabled "Switch to Desktop N" shortcut in macOS. Make them match. |
| **Turn on “Displays have separate Spaces”** | Several displays are connected but the setting is off. Turn it on in System Settings ▸ Desktop & Dock ▸ Mission Control, then log out. Shown once per run. |
| **Rectangle is running** | Rectangle also moves windows. Quit it if windows jump around. hyprMac shows this once per run and never touches Rectangle. |
| **Accessibility permission was removed** | hyprMac stopped tiling. Turn it back on and tiling resumes. |

## Configuration and reloading
The config is `~/.config/hyprmac/init.lua`. The keys and their ranges are in the [README](../README.md#configuration) and in the file's comments. `osd_popup = false` turns off the on-screen popup.

Saving the file reloads it automatically (about 0.3 s after the last write). You can also use the menu's **Reload Configuration**, `hyprmacctl reload`, or `pkill -HUP -x hyprMac`. A plain `pkill -x hyprMac` quits. A file with an error keeps the previous settings and shows the usual notification.

To check a file without running the app: `hyprMac --check-config [path]` prints `OK` or `file:line: message` and exits 0 or 1. Without a path it checks `--config`, then `~/.config/hyprmac/init.lua`. It never starts the app or touches your shortcuts.

### Keys and app rules

```lua
config = {
    osd_popup = true,                     -- brief on-screen popup on window and Desktop actions
    keys = {
        throw        = "alt+shift",       -- modifiers + 1–9: move the focused window to Desktop N
        toggle_float = "alt+shift+f",     -- modifiers + one key: float / tile the focused window
        switch       = "alt",             -- modifiers hyprMac watches for with 1–9 (see below)
        center_window = "alt+shift+c",    -- center the focused window
        focus_left  = "alt+shift+h",      -- focus_left / _down / _up / _right: move focus
        focus_down  = "alt+shift+j",
        focus_up    = "alt+shift+k",
        focus_right = "alt+shift+l",
        move_left   = "alt+shift+cmd+h",  -- move_left / _down / _up / _right: move/swap the window
        move_down   = "alt+shift+cmd+j",
        move_up     = "alt+shift+cmd+k",
        move_right  = "alt+shift+cmd+l",
    },
    rules = {
        ignore = { "com.example.app" },      -- never managed, never moved, no throw or toggle
        float  = { "com.apple.calculator" }, -- always floating; ⌥⇧F can still tile it
    },
}
```

- **Names** are joined with `+` and are not case-sensitive. Modifiers: `alt` (`opt`, `option`), `shift`, `ctrl` (`control`), `cmd` (`command`). Keys: `a`–`z`, `0`–`9`, `f1`–`f12`, `space`, `tab`, `return`, `escape`, `grave`, `minus`, `equal`, `comma`, `period`, `slash`.
- `throw` and `switch` are modifiers only. `toggle_float`, `center_window`, `focus_*` and `move_*` need at least one modifier and exactly one key. Setting any `focus_*` (or `move_*`) key replaces that group's defaults, so the default arrow keys stop working. `throw` must differ from `switch`, and `toggle_float` can't be a throw shortcut like `alt+shift+3`.
- **`switch` doesn't switch Desktops.** macOS does that, with the shortcuts under Mission Control. `switch` only tells hyprMac which keys to watch for the missing-Desktop notice. A throw reads the modifiers from macOS's own shortcut (`com.apple.symbolichotkeys`, read only) and uses `switch` only if that can't be read.
- **More actions** (`resize_left`, `resize_down`, `resize_up`, `resize_right`, `equalize`, `rotate_split`, `toggle_zoom`, `move_display_next`, `move_display_prev`, `toggle_pause`) take modifiers plus one key like `toggle_float`, and can't reuse another configured or default shortcut or a Desktop digit chord.
- **macOS conflicts.** On every load, each shortcut except the throw prefix is compared with the enabled shortcuts in System Settings. A match isn't registered, and a notice says which (for example `⌥⇧F conflicts with a macOS shortcut (Spotlight)`). Nothing in System Settings is changed.
- **`resize_step`** (top level of `config`, not under `keys`) is the percent of a split one resize press moves: 1–25, default 5.
- **Rules** take bundle ids (`osascript -e 'id of app "Calculator"'`), up to 200 per list. `float` adds to the built-in list. An app in `ignore` is skipped entirely, including by the throw and toggle shortcuts.

### Title rules, gaps and focus

All of these are off or equal to today's behaviour unless you set them. New actions have no default shortcut.

```lua
config = {
    smart_gaps = true,            -- one tiled window on a Space: zero inner and zero outer gap
    displays = { ["Studio Display"] = { inner = 4, outer = 8 } },
    focus_follows_mouse = true,
    rules = {
        float_title  = { "^Picture.in.Picture$" },
        ignore_title = { "^Zoom Meeting$" },
        desktop      = { ["com.apple.Music"] = 3 },   -- EXPERIMENTAL
    },
}
```

- **Title rules** are case-insensitive regexes (ECMAScript) searched anywhere in the title, so anchor with `^` and `$`. Up to 200 per list, 128 characters each. A bad pattern is a config error with the file and line. Back-references and a repeated group that contains a repeat, like `(a+)+`, are refused because they can run for a very long time. Titles are cut to 512 characters before matching. A window is checked once, against the first non-empty title it shows, and that decision sticks (browser titles change all the time). `float_title` floats like `rules.float`, so ⌥⇧F can tile it. `ignore_title` acts like `rules.ignore` for that window: never tiled, never thrown.
- **`smart_gaps`**: a Space with exactly one tiled window gets zero inner and zero outer gap, so the window fills the usable area. Floating windows don't count.
- **`displays`** overrides the gaps for the display with that name (`NSScreen.localizedName`, as shown in System Settings ▸ Displays). Either side may be left out to keep the global gap. Names that match no connected display are ignored and listed in the log.
- **`focus_follows_mouse`**: resting the pointer on a tiled or floating window for about 120 ms focuses it. It never moves the cursor, never refocuses the focused window, and ignores mouse movement for 0.4 s after hyprMac itself moves the cursor (directional focus, throws), so the two don't fight. The menu bar, Dock and ignored apps never take focus.
- **`rules.desktop`** (EXPERIMENTAL, empty by default): the first time a new window of the app shows up on another Desktop, hyprMac throws it to Desktop N (1–9) with the same drag trick as ⌥⇧N. That switches Desktops under you. Windows that were already open when hyprMac started, floating or fullscreen windows, ignored apps and windows already on Desktop N are left alone. Each window is tried once. If the throw fails (`noGrabPoint`, `timedOut`), it is logged and not retried.

If the config has an error, nothing changes. hyprMac keeps the last good settings and tells you what's wrong. A missing file means the defaults.

## Command line
`hyprmacctl` talks to the running app. It lives inside the bundle and isn't linked anywhere else:

```sh
~/Applications/hyprMac.app/Contents/MacOS/hyprmacctl status
```

| Command | What it does |
|---|---|
| `status` | Prints JSON: `version`, `paused`, `displays`, `spaces`, `config`. |
| `retile` | Same as **Retile All Windows**. |
| `pause` / `resume` / `toggle-pause` | Stops or restarts tiling. |
| `reload` | Same as **Reload Configuration**. |

Exit status: 0 ok, 1 refused or failed, 2 bad usage, 3 hyprMac isn't running. The socket is `$TMPDIR/dev.codesmith28.hyprmac.sock` (mode 0600, local only, removed on quit).

## Logs

```sh
log stream --level info --predicate 'subsystem == "dev.codesmith28.hyprmac"'
```

This shows what hyprMac decided: windows it floated, throws that timed out, hotkeys that didn't register, config errors.

## Troubleshooting

### Nothing tiles
Check these in order:
1. **Is tiling paused?** If the icon is dimmed, the menu will say **Resume Tiling**.
2. **Is Stage Manager on?** Turn it off in Control Center. Right after install, that's expected until you toggle it once or log out.
3. **Does hyprMac have Accessibility?** System Settings ▸ Privacy & Security ▸ Accessibility. After a rebuild or upgrade, the old grant doesn't match the new signature, even if the switch is on. Remove hyprMac with "−", add `~/Applications/hyprMac.app` again, or toggle it off and on. To stop this happening on every upgrade, run `make sign-identity` once (see [limitations](LIMITATIONS.md#accessibility-permission-resets-on-reinstall)).
4. **Is the window one hyprMac leaves alone?** Dialogs, sheets, panels, palettes, non-resizable windows, windows without a close button, Archive Utility and Calculator float on purpose.
5. **Was it small?** A window smaller than `float.min_width` × `float.min_height` (default 400 × 300) floats when hyprMac first sees it. The log says `"reason":"small"`. That decision sticks. Set a threshold to 0 to turn it off.
6. **Is it fighting the tile?** A window that resizes itself away from its tile 3 times in 10 seconds gets floated. The log says `floating it`. **Retile All Windows** tries again.
7. **Is another window manager running?** Rectangle, yabai, Amethyst, AeroSpace and similar tools can undo hyprMac's work. Quit them.

### ⌥N doesn't switch Desktops
macOS does the switching, so check there:
1. System Settings ▸ Keyboard ▸ Keyboard Shortcuts… ▸ **Mission Control**.
2. Make sure **Switch to Desktop N** is ticked and set to ⌥N. Install adds ⌥8 and ⌥9 if they were free. ⌥1–⌥7 are yours to set.
3. Desktop N has to exist. Add Desktops with the "+" in Mission Control.
4. macOS ignores presses made while a Desktop switch is still animating. Wait, then press again.

### ⌥⇧N doesn't move the window
- The throw presses ⌥N for you, so fix ⌥N first.
- The window needs a plain titlebar spot to hold. Windows whose titlebar is all tabs or toolbar, windows with custom chrome, and windows with no titlebar can't be thrown. You'll get "no titlebar area to grab", and nothing moves. Use Mission Control for those.
- Fullscreen windows can't be thrown.
- Another app or a macOS shortcut may already use ⌥⇧N. macOS doesn't report that clash, so the other app may get the key. Check System Settings ▸ Keyboard ▸ Keyboard Shortcuts, and your launchers and window managers. hyprMac only logs `hotkeys ⌥⇧[…] failed to register` for clashes inside hyprMac itself.

### No "Desktop N doesn't exist" notice
That notice needs **Input Monitoring** (System Settings ▸ Privacy & Security ▸ Input Monitoring). Without it, everything else works, and the log says `space key observer unavailable`. Notifications must also be allowed for hyprMac.

### Windows land in the wrong place on a second display
Turn on System Settings ▸ Desktop & Dock ▸ **Displays have separate Spaces**. Log out and back in after changing it.
