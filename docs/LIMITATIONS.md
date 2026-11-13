# Limitations

What macOS makes impossible or fragile for a tiler that keeps native Spaces, and how hyprMac copes. Behaviour marked *verified* was seen on a real Mac and is recorded in [QUIRKS.md](QUIRKS.md).

## Moving windows between Spaces
macOS has no public API for moving a window to another Space. The private SkyLight calls that can do it need System Integrity Protection partly off. That's how yabai works. hyprMac doesn't go that way.

Instead, ⌥⇧N uses the **drag trick**:
1. Find a safe point in the titlebar, 8 pt below the top edge. Candidates are 25 %, 50 % and 75 % of the width, and 80 pt from the left, just past the traffic lights. A point is accepted only if Accessibility says it's the window itself or a plain titlebar or tab-strip area. Buttons, tabs, text fields, pop-ups and toolbars are rejected.
2. Post a mouse-down there, then the native ⌥N.
3. Wait up to 1 s for the active Space to become Desktop N, then 0.4 s more for the animation.
4. Post the mouse-up and put the cursor back. This always happens, even on failure.

The window moves with the "drag" and stays focused on the new Desktop. It works on ordinary AppKit windows, and on Chrome and Brave by grabbing the tab-strip background (*verified*). It fails in these cases:

| Result | When | What you see |
|---|---|---|
| `noGrabPoint` | No safe titlebar spot. The titlebar is all tabs, a unified toolbar covers every candidate, the chrome is custom, or there's no titlebar. | "This window has no titlebar area to grab." Nothing moves. |
| `timedOut` | The Space didn't change within 1 s. Usually ⌥N isn't bound to "Switch to Desktop N". | A notification asking you to check that binding. |
| `noSuchSpace` | Desktop N doesn't exist on that display. | "Desktop N doesn't exist." |
| `refusedFullscreen` | The window is fullscreen and has its own Space. | A notification. |
| `transitionInFlight` | A Space switch is still animating. | Nothing. Press again. |
| `alreadyThere` | The window is already on Desktop N. | Nothing. |

**Presses during a Space animation are dropped** (*verified*). hyprMac won't start a throw within 0.5 s of the last Space change. Your own ⌥N presses during an animation can be dropped the same way. That's macOS.

**One throw at a time.** A ⌥⇧N pressed during a throw is ignored.

**Spaces are fixed.** hyprMac can't create or delete them. Use Mission Control.

**Tabs and toolbars are never pressed.** A mouse-down on a tab would drag it out into a new window, and one on a button would press it. If every candidate lands on a tab, button, toolbar or title, hyprMac returns `noGrabPoint` rather than guess. Native tab bars sit below the titlebar, so the titlebar is still grabbable. Apps that draw tabs *inside* the titlebar can't be thrown.

## Private SkyLight symbols (read-only)
To know the active Space, how many Desktops exist and which Space a window is on, hyprMac looks up a few private functions at runtime with `dlsym`:
- `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`, `CGSManagedDisplayGetCurrentSpace`
- `_AXUIElementGetWindow`, which maps an Accessibility window to its window id

hyprMac only reads with them. It never calls a private function that changes anything.

- **Numbering.** Desktop N is the Nth user Space (`type == 0`) on that display, in Mission Control order. Space ids aren't contiguous (this Mac's are 4, 5, 6 and 8), so N is never used as an id.
- **Fallback.** If a future macOS removes these symbols, hyprMac falls back to one synthetic Space per display. Tiling still works on what's on screen. The missing-Desktop notice and throw targets don't, and a throw reports `noSuchSpace`.

## Stage Manager
Stage Manager moves and groups windows on its own, which fights the tiler. While `com.apple.WindowManager GloballyEnabled` is on, hyprMac pauses and says "Tiling paused: Stage Manager is on". It checks on every window event and Space change, and resumes once Stage Manager is off.

`make install` writes `GloballyEnabled = false` and records the old value. `make uninstall` restores it. **macOS doesn't apply the write live.** Stage Manager stays on, and hyprMac stays paused, until you toggle it off in Control Center or log out. The reverse holds too: if uninstall turns it back on, toggle it on in Control Center (or log out) to see it.

## "Displays have separate Spaces" is required
With this setting on (the macOS default), each display has its own Spaces, and hyprMac tiles each display from its own active Space. With it off, macOS reports one shared set of Spaces for all displays. Per-display numbering and throws then become unreliable.

hyprMac reads the setting but doesn't warn when it's off, and install doesn't check it. Keep it on.

## Fullscreen detection varies by app
A window counts as fullscreen when its `AXFullScreen` attribute says so. Native fullscreen (the green button, ⌃⌘F) sets it reliably. Some apps don't:
- Games and media players with their own fullscreen mode may just cover the screen with a borderless window.
- Some presentation modes behave the same way.
- Apps that *zoom* (⌥-click the green button) get a big window, not a fullscreen one.

Such windows are tiled, or float if they're borderless or non-resizable. They don't get a ghost slot.

## Apps that refuse to be resized
- **Minimum sizes.** When a window won't shrink to its tile, hyprMac learns its minimum and lays the Space out again around it. Siblings shrink on both axes until it fits. A window that reports `AXMinimumSize` up front gets this on the first layout. If the siblings can't make room (two 900 pt windows on a 1512 pt screen, say), hyprMac splits the space in proportion to the minimums and stops. The windows overlap, but nothing loops. When a window closes and the minimum becomes satisfiable, it's honoured again.
- **Windows that fight.** A tiled window that changes its own frame away from its tile 3 times within 10 seconds is floated (log reason `fights`). **Retile All Windows** forgets that and tries again.
- **Unresponsive apps.** Each Accessibility request waits at most about a quarter of a second. An app that doesn't answer is skipped for that round and retried soon after. Its windows keep their tiles, and other apps keep tiling. Each pass over a hung app costs a fraction of a second, so tiling can feel a bit slower while one is hung.

## Accessibility permission resets on reinstall
By default hyprMac is **ad-hoc signed** (no Developer ID). macOS ties the Accessibility grant to the exact signature, and that changes with every build.
- A **fresh** `make install` resets the entry and opens the settings pane. Grant it once.
- **Upgrading** resets the entry again, because the new build no longer matches the old grant. Grant it again when System Settings opens.
- **Opt-in fix:** `make sign-identity` creates a self-signed code-signing certificate, "hyprMac Local Signing", in your **login keychain** (the key is not exportable). While it exists, `make app` and `make install` sign with it. Its signature is the same on every build, so after one more grant the permission survives upgrades. If hyprMac is already installed, run `make update` afterwards.
- The certificate isn't trusted by macOS and only gives the app a stable identity. macOS may ask for your login password the first time `codesign` uses the key: choose Always Allow.
- `make sign-identity-remove` deletes it. `make uninstall` removes it only if it was created while hyprMac was installed. One that existed before install stays. Deleting and recreating the certificate changes the identity, so you grant Accessibility once more.
- **Input Monitoring** powers the "Desktop N doesn't exist" notice. Install doesn't ask for it. Without it, switching and throwing still work. The log says `space key observer unavailable`.

## Hotkeys already taken by another app
⌥⇧1–9 are registered with the Carbon hotkey API. macOS only rejects a duplicate **within the same app**. If another app or a macOS shortcut already uses ⌥⇧N, hyprMac's registration still succeeds, and macOS picks whoever gets the key. hyprMac can't detect that clash. If a throw does nothing, look for another app or a System Settings shortcut using ⌥⇧1–9.

## What verify-rollback cannot see
`make verify-rollback` and the check at the end of `make uninstall` compare fingerprints of what install changes: hotkeys 125 and 126, the Stage Manager key, the notification settings entry, whether the LaunchAgent is loaded, the LaunchServices records for `~/Applications/hyprMac.app`, the app bundle and agent contents, whether the local signing identity exists, and the config, state and residue paths.

Some things are out of reach:
- **Background Task Management.** The LaunchAgent makes macOS record a login item (`sfltool dumpbtm` shows it). A user script can't read that database, so macOS may keep a stale entry after uninstall.
- **Unified logs.** Entries under `dev.codesmith28.hyprmac` stay until macOS rotates them out.
- **The TCC database.** It needs Full Disk Access to read. Uninstall resets hyprMac's entry, but the snapshot can't confirm it.
- **Live versus stored state.** The snapshot compares preferences, not what the system is showing. Hotkeys are re-applied with `activateSettings`, but if that tool is missing you need a logout. Stage Manager's preference can match the snapshot while Control Center still shows the old state.
