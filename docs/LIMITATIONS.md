# Limitations

This is an honest account of what macOS makes impossible or fragile for a tiler that keeps native Spaces, and how hyprMac copes. Behaviour marked *verified* was observed on a real machine (macOS 27.2, Apple silicon) and is recorded in [QUIRKS.md](QUIRKS.md).

## Moving windows between Spaces
macOS has **no public API** to move a window to another Space. The private SkyLight calls that can do it need System Integrity Protection partly disabled (this is the route yabai takes). hyprMac doesn't go there.

Instead ⌥⇧N uses the **drag trick** (`SpaceMover`):
1. Find a safe point in the window's titlebar, 8 pt below its top edge. The candidates are 25 %, 50 % and 75 % of the width, and 80 pt in from the left (just right of the traffic lights). A point is only accepted if Accessibility hit-testing says it is the window itself or a plain titlebar or tab-strip area (`AXGroup`, `AXUnknown`). Buttons, tabs, text fields, pop-ups and toolbars are rejected.
2. Post a mouse-down there, then the native ⌥N.
3. Wait (up to 1 s) for the active Space to become Desktop N, then another 0.4 s for the animation to settle.
4. Post the mouse-up and put the cursor back where it was. The mouse-up and cursor restore always happen, even on failure.

The window travels with the "drag" and stays focused on the new Desktop. It works with ordinary AppKit windows, and with Chrome/Brave windows by grabbing the tab-strip background (*verified*). It fails in these cases:

| Result | When | What you see |
|---|---|---|
| `noGrabPoint` | The window has no titlebar area that is safe to grab: custom-drawn chrome, a full-width toolbar, or no titlebar at all | Notification: "This window has no titlebar area to grab." |
| `timedOut` | The Space didn't change within 1 s, usually because ⌥N is not bound to "Switch to Desktop N" | Notification asking whether ⌥N is bound |
| `noSuchSpace` | Desktop N doesn't exist on that display | "Desktop N doesn't exist" notification |
| `refusedFullscreen` | The window is fullscreen (it already has its own Space) | Notification |
| `transitionInFlight` | A Space switch is still animating | Nothing happens; press again |
| `alreadyThere` | The window is already on Desktop N | Nothing happens |

**Keys pressed during a Space animation are dropped** (*verified*). A ⌥N posted while a Space transition is still animating is silently ignored by macOS. hyprMac tracks transitions and refuses to start a throw within 0.5 s of the last one, which is the `transitionInFlight` case above. Your own ⌥N presses during an animation can be dropped the same way; that is macOS behaviour.

**One throw at a time.** A ⌥⇧N pressed while a throw is in progress is ignored.

**Spaces themselves are fixed.** hyprMac can't create or delete Spaces; use Mission Control for that.

## Private SkyLight symbols (read-only)
To know which Space is active, how many Desktops exist and which Space a window is on, hyprMac resolves a few private SkyLight functions at runtime with `dlsym`:
- `CGSMainConnectionID`
- `CGSGetActiveSpace`
- `CGSCopyManagedDisplaySpaces`
- `CGSCopySpacesForWindows`
- `CGSManagedDisplayGetCurrentSpace`
- `_AXUIElementGetWindow`, which maps an Accessibility window to its window id

They are only ever used to **read**. hyprMac never calls a private function that changes anything.

- **Space numbering.** Desktop N is the N-th *user* Space (`type == 0`) on that display, in Mission Control order. Space ids are not contiguous (this Mac's are 4, 5, 6 and 8), so N is never treated as an id.
- **Fallback.** If a future macOS removes or renames these symbols, hyprMac falls back to one synthetic Space per display. Tiling keeps working on whatever is on screen, but the "Desktop N doesn't exist" notice and throw targets are unavailable, and a throw reports `noSuchSpace`.

## Stage Manager is incompatible
Stage Manager groups, shrinks and moves windows on its own, which conflicts with tiling. Whenever hyprMac sees `com.apple.WindowManager GloballyEnabled` is on, it **pauses** and shows "Tiling paused: Stage Manager is on". It checks again on every window event and Space change, and resumes by itself once Stage Manager is off.

`make install` writes `GloballyEnabled = false` and `make uninstall` restores the previous value. If Control Center still shows Stage Manager on after installing, switch it off there.

## "Displays have separate Spaces" is required
With the setting on, which is the macOS default, every display has its own Spaces and hyprMac tiles each display from its own active Space. With it off, macOS reports a single shared set of Spaces for all displays. hyprMac then uses that shared set for every display, so per-display Space numbering and throws become unreliable.

hyprMac reads this setting but **does not currently warn** when it is off, and `make install` doesn't check it either. Keep it on.

## Fullscreen detection varies by app
A window counts as fullscreen when its Accessibility `AXFullScreen` attribute says so. Native macOS fullscreen (the green button, ⌃⌘F) sets it reliably. Some apps don't:
- Games and media players with their own "fullscreen" mode may just cover the screen with a borderless window.
- Some apps' "presentation" modes behave the same way.
- Apps that *zoom* (⌥-click the green button) instead of going fullscreen get a big window, not a fullscreen one.

Such windows are tiled, or float if they are borderless or non-resizable, instead of getting a placeholder. Their tile is not kept for them.

## Apps that refuse to be resized
Some apps clamp sizes, enforce a minimum size, or snap back to their own size after any resize.
- **Minimum sizes.** When a window refuses to become smaller than its tile, hyprMac learns the minimum and lays the Space out again around it, giving the window more room where geometrically possible.
- **Windows that fight.** A tiled window that changes its own frame away from its tile **3 times within 10 seconds** is treated as floating from then on, so hyprMac and the app don't loop forever. It is logged as `floated` with reason `fights`. Menu bar ▸ **Retile All Windows** forgets these decisions and tries again.
- **Hung apps.** Accessibility calls to a hung app time out. Frames are written on one queue per app, so a hung app delays only its own windows.

## Accessibility permission resets on reinstall
hyprMac is **ad-hoc signed** (no Apple Developer ID). macOS ties the Accessibility grant to the exact code signature, and an ad-hoc signature changes with every build, so a rebuilt app no longer matches the old grant.
- A **fresh** `make install` resets hyprMac's Accessibility entry (`tccutil reset`) and opens the settings pane, so you grant it once, cleanly.
- **Upgrading** (running `make install` again over an existing install) replaces the app but does *not* reset the entry. If tiling doesn't start afterwards, remove hyprMac from the Accessibility list with "−", add it again, or toggle it off and on.
- **Input Monitoring.** The ⌥N listener behind the "Desktop N doesn't exist" notice is a listen-only keyboard event tap, which needs Input Monitoring permission. Install doesn't ask for it. Without it, Space switching and throws still work; only the missing-Desktop notice is disabled. hyprMac logs "space key observer unavailable" in that case.

## What verify-rollback cannot see
`make verify-rollback` and the check at the end of `make uninstall` compare fingerprints of everything install changes:
- hotkeys 125/126 and the Stage Manager key;
- hyprMac's notification settings entry;
- whether the LaunchAgent is loaded;
- the LaunchServices registration count;
- the app bundle and LaunchAgent contents;
- the config, state and residue paths.

Some system records are outside its reach:
- **Background Task Management.** Adding the LaunchAgent makes macOS record a login item ("background item added", visible with `sfltool dumpbtm`). That database is not readable by a user script, so it isn't compared, and macOS may keep a stale entry after uninstall.
- **Unified logs.** hyprMac logs under the subsystem `dev.codesmith28.hyprmac`, and macOS logs installs, launches and permission prompts. These entries stay until macOS rotates them out.
- **The Accessibility (TCC) database.** It can't be read without Full Disk Access. Uninstall resets hyprMac's entry, but the snapshot can't confirm it.
- **Live state versus stored state.** The snapshot compares preferences, not what the system is currently showing. For example, the hotkeys are re-applied with `activateSettings`, but if that tool is missing a logout is needed for the change to take effect.
