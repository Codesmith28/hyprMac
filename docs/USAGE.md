# Using hyprMac

hyprMac runs in the menu bar (a 2×2 grid icon) and has no Dock icon. After `make install` it starts at every login.

## Shortcuts
| Keys | Action |
|---|---|
| ⌥1 … ⌥9 | Switch to Desktop N. This is the **native** macOS shortcut; hyprMac only listens so it can warn you when Desktop N doesn't exist |
| ⌥⇧1 … ⌥⇧9 | Move the focused window to Desktop N. You follow it, and it keeps focus |

New windows tile automatically. The window that has focus is split along its longer side, and the new window takes the second half. Close, minimize, hide or fullscreen a window and the others reflow. When it comes back, it gets its old tile.

The menu bar item ▸ **Keyboard Shortcuts…** shows the same list.

## The menu
| Item | What it does |
|---|---|
| **Pause Tiling** / **Resume Tiling** | Stop or restart arranging windows. While paused, windows stay where they are and the icon is dimmed. Pausing lasts until you resume or quit; it isn't remembered across launches |
| **Retile All Windows** | Lay every Space out again. It also gives windows another chance that hyprMac had floated because they kept resizing themselves |
| **Open Configuration…** (⌘,) | Opens `~/.config/hyprmac/init.lua`, creating it from the example if it doesn't exist |
| **Reload Configuration** (⌘R) | Re-reads the config file and re-lays out with the new values |
| **Keyboard Shortcuts…** | The shortcut cheat sheet |
| **Quit hyprMac** (⌘Q) | Quits. Windows stay where they are. With the LaunchAgent installed, hyprMac starts again at your next login |

The ⌘ shortcuts work while the menu is open.

## Notifications
hyprMac asks for permission to show notifications the first time it runs. If you decline, the same messages still go to the system log (see [Logs](#logs)).

| Notification | Meaning |
|---|---|
| **Desktop N doesn't exist** | You pressed ⌥N or ⌥⇧N for a Desktop you don't have. Add Desktops in Mission Control |
| **Couldn't move window to Desktop N** | A throw failed. The body says why: no titlebar area to grab, a fullscreen window, macOS didn't switch in time, or an Accessibility error. See [LIMITATIONS](LIMITATIONS.md#moving-windows-between-spaces) |
| **Configuration error — kept previous settings** | `init.lua` failed to load. The body has `file:line: message` |
| **Tiling paused: Stage Manager is on** | Turn Stage Manager off in Control Center; tiling resumes by itself. This also appears right after `make install` until you toggle Stage Manager off once (or log out): install writes the setting, but macOS only applies it live after that |
| **Rectangle is running** | Rectangle can move windows too. Quit it if windows jump around. hyprMac shows this once per run and never touches Rectangle |
| **Accessibility permission was removed** | hyprMac stopped tiling. Re-enable it in System Settings and it resumes automatically |

## Configuration and reloading
The config file is `~/.config/hyprmac/init.lua`. The keys and their ranges are in the [README](../README.md#configuration) and in the file's own comments.

To apply an edit, use one of these:
- the menu bar item ▸ **Reload Configuration**;
- from a terminal: `pkill -HUP -x hyprMac`. hyprMac reloads on `SIGHUP`, and a plain `SIGTERM` (`pkill -x hyprMac`) quits it cleanly.

If the file has an error, nothing changes: hyprMac keeps the last good settings and tells you the file, line and problem. A missing file means the built-in defaults (inner gap 8, outer gap 12, split ratio 0.5).

## Logs
```sh
log stream --level info --predicate 'subsystem == "dev.codesmith28.hyprmac"'
```
This shows what hyprMac decides: windows it floated, throws that timed out, hotkeys that couldn't be registered, config errors.

## Troubleshooting

### Nothing tiles
Go through these in order:
1. **Is tiling paused?** If the menu bar icon is dimmed, open the menu: **Resume Tiling** means you paused it.
2. **Is Stage Manager on?** If so, hyprMac pauses itself and says so. Turn it off in Control Center. Right after `make install` this is expected: install writes the setting, but macOS only applies it live once you toggle Stage Manager off in Control Center (or log out and back in).
3. **Does hyprMac have Accessibility permission?** Check System Settings ▸ Privacy & Security ▸ Accessibility. After a rebuild or an upgrade install, the old grant no longer matches the new ad-hoc signature even if the switch shows on: remove hyprMac with "−" and add it again (`~/Applications/hyprMac.app`), or toggle it off and on. Tiling starts within a second of the grant.
4. **Is it a window hyprMac deliberately leaves alone?** Dialogs, sheets, panels, palettes, non-resizable windows, windows without a close button, Archive Utility and Calculator float by design.
5. **Did the window fight back?** A window that resized itself away from its tile 3 times within 10 seconds is floated (the log says `floating it`), so hyprMac and the app don't loop. **Retile All Windows** un-floats it and tries again.
6. **Is another window manager running?** Rectangle, yabai, Amethyst, AeroSpace and similar tools can undo hyprMac's work. Quit them.

### ⌥N doesn't switch Desktops
The switch itself is done by macOS, not hyprMac:
1. Open System Settings ▸ Keyboard ▸ Keyboard Shortcuts… ▸ **Mission Control**.
2. Expand Mission Control and make sure **Switch to Desktop N** is ticked and set to ⌥N. `make install` adds ⌥8 and ⌥9 if they were unbound; ⌥1–⌥7 are yours to set.
3. Desktop N must exist. Add Desktops in Mission Control (the "+" at the top right).
4. Presses made while a Desktop-switch animation is still running are ignored by macOS. Press again once it finishes.

### ⌥⇧N doesn't move the window
- The throw needs ⌥N to work, because it presses ⌥N for you; fix that first.
- The window needs a plain titlebar area to "hold". hyprMac only presses on empty titlebar space, never on a button, tab, toolbar item or text. Windows whose titlebar is entirely tabs or toolbar (for example a terminal with tabs in the titlebar, or a unified toolbar), custom chrome or no titlebar can't be thrown; you get "no titlebar area to grab" and nothing moves. Use Mission Control to move those windows.
- Fullscreen windows can't be thrown.
- Another app or a macOS shortcut may already use ⌥⇧N. macOS doesn't tell hyprMac about that (registration succeeds anyway), so the other app may get the key instead. Check System Settings ▸ Keyboard ▸ Keyboard Shortcuts and the apps you run (window managers, launchers, clipboard tools) for ⌥⇧1–9. hyprMac only logs `hotkeys ⌥⇧[…] failed to register` when the clash is inside hyprMac itself.

### No "Desktop N doesn't exist" notice
That notice relies on a listen-only keyboard monitor, which needs **Input Monitoring** permission (System Settings ▸ Privacy & Security ▸ Input Monitoring). Without it everything else works, and the log says `space key observer unavailable`. Notifications must also be allowed for hyprMac.

### Windows land in the wrong place on a second display
Make sure System Settings ▸ Desktop & Dock ▸ **Displays have separate Spaces** is on. A change to that setting takes effect after you log out and back in.
