# Using hyprMac

hyprMac lives in the menu bar (the 2×2 grid icon). It has no Dock icon. After `make install` it starts at login.

## Shortcuts

| Keys | Action |
|---|---|
| ⌥1 … ⌥9 | Switch to Desktop N. macOS does this. hyprMac only listens, to warn you when Desktop N doesn't exist. |
| ⌥⇧1 … ⌥⇧9 | Move the focused window to Desktop N. You follow it, and it keeps focus. |
| ⌥⇧F | Float or tile the focused window. Floating restores the size hyprMac first saw, centred. The choice sticks until you toggle again or close the window. Fullscreen windows are ignored. |
| ⌃⌥C | Center the focused window. If tiled, floats and centers it at its original size. |
| ⌃⌥H / J / K / L or ⌃⌥← / ↓ / ↑ / → | Move focus in the BSP tree (left, down, up, right). |
| ⌃⌥⇧H / J / K / L or ⌃⌥⇧← / ↓ / ↑ / → | Move/swap the focused window in the BSP tree (left, down, up, right). Focus follows the moved window. |

These are the defaults. You can change them under [keys](#keys-and-app-rules). The menu's **Keyboard Shortcuts…** shows the same list.

New windows split the focused window along its longer side and take the second half. Close, minimize, hide or fullscreen a window and the rest reflow. When it comes back, it gets its old tile.

### Resizing by hand
Drag a tiled window's edge and let go. hyprMac keeps the new size.

- The split next to that edge moves with it, and the neighbours reflow. The new ratio sticks for later layouts.
- Ratios stay between 10 % and 90 %, and within the windows' minimum sizes.
- An edge on the screen boundary, or a window with no split on that axis, snaps back.
- Dragging a tiled window by its titlebar and dropping it onto another tile swaps the two tiles in the tree.
- Dragging a floating window keeps its new position without snapping back.
- Moving a tiled window within its own tile snaps it back.
- A window that resizes itself, without the mouse, still counts as a fight.

The log line is `{"event":"user_resize",...}`.

## Menu

| Item | What it does |
|---|---|
| **Pause Tiling** / **Resume Tiling** | Stops or restarts tiling. While paused, windows stay where they are, and the icon is dimmed and changes to a pause symbol. Remembered across launches. |
| **Retile All Windows** | Lays out every Space again. Also gives back windows that were floated for fighting their tile. |
| **OSD Popups** | Checkmark toggle for the small on-screen popups. Remembered in `~/.config/hyprmac/state.json`; until you use it, `osd_popup` in the config decides. |
| **Launch at Login** | Checkmark toggle. Enabled only when `make install` created the login item. Uses `launchctl enable/disable`. |
| **Open Configuration…** | Opens `~/.config/hyprmac/init.lua`, creating it from the example if needed. |
| **Reveal Configuration in Finder** | Shows the config file in Finder. |
| **Reload Configuration** | Re-reads the config and re-lays out. |
| **Keyboard Shortcuts…** | Lists your current shortcuts, including any you changed under `keys`. |
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
| **Rectangle is running** | Rectangle also moves windows. Quit it if windows jump around. hyprMac shows this once per run and never touches Rectangle. |
| **Accessibility permission was removed** | hyprMac stopped tiling. Turn it back on and tiling resumes. |

## Configuration and reloading
The config is `~/.config/hyprmac/init.lua`. The keys and their ranges are in the [README](../README.md#configuration) and in the file's comments.

To apply an edit, use the menu's **Reload Configuration**, or run `pkill -HUP -x hyprMac`. A plain `pkill -x hyprMac` quits.

### Keys and app rules

```lua
config = {
    keys = {
        throw        = "alt+shift",       -- modifiers + 1–9: move the focused window to Desktop N
        toggle_float = "alt+shift+f",     -- modifiers + one key: float / tile the focused window
        switch       = "alt",             -- modifiers hyprMac watches for with 1–9 (see below)
    },
    rules = {
        ignore = { "com.example.app" },      -- never managed, never moved, no throw or toggle
        float  = { "com.apple.calculator" }, -- always floating; ⌥⇧F can still tile it
    },
}
```

- **Names** are joined with `+` and are not case-sensitive. Modifiers: `alt` (`opt`, `option`), `shift`, `ctrl` (`control`), `cmd` (`command`). Keys: `a`–`z`, `0`–`9`, `f1`–`f12`, `space`, `tab`, `return`, `escape`, `grave`, `minus`, `equal`, `comma`, `period`, `slash`.
- `throw` and `switch` are modifiers only. `toggle_float` needs at least one modifier and exactly one key. `throw` must differ from `switch`, and `toggle_float` can't be a throw shortcut like `alt+shift+3`.
- **`switch` doesn't switch Desktops.** macOS does that, with the shortcuts under Mission Control. `switch` only tells hyprMac which keys to watch for the missing-Desktop notice. A throw reads the modifiers from macOS's own shortcut (`com.apple.symbolichotkeys`, read only) and uses `switch` only if that can't be read.
- **Rules** take bundle ids (`osascript -e 'id of app "Calculator"'`), up to 200 per list. `float` adds to the built-in list. An app in `ignore` is skipped entirely, including by the throw and toggle shortcuts.

If the config has an error, nothing changes. hyprMac keeps the last good settings and tells you what's wrong. A missing file means the defaults.

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
3. **Does hyprMac have Accessibility?** System Settings ▸ Privacy & Security ▸ Accessibility. After a rebuild or upgrade, the old grant doesn't match the new signature, even if the switch is on. Remove hyprMac with "−", add `~/Applications/hyprMac.app` again, or toggle it off and on.
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
