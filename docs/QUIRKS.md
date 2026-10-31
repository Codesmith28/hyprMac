# macOS quirks

What I checked on a real Mac: macOS 27.2, Apple silicon, on 2026-10-31. Everything here was observed, not assumed.

## Verified
- `_AXUIElementGetWindow`, looked up with `dlsym`, returns the same id as `NSWindow.windowNumber`.
- The read-only SkyLight calls resolve and work: `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`, `CGSManagedDisplayGetCurrentSpace`, and the `SLS*` aliases.
- `CGSCopyManagedDisplaySpaces` returns one dict per display, with `Display Identifier`, `Current Space.ManagedSpaceID` and `Spaces[]`. Each space has `ManagedSpaceID` and `type` (0 = user, 4 = fullscreen). The user Space IDs here are 4, 5, 6 and 8. They aren't contiguous and aren't the index.
- **The drag trick works.** A mouse-down on the titlebar, then ⌥1 posted at `.cghidEventTap`, then mouse-up moved the window. The active Space changed 373 ms after the mouse-down, and `CGSCopySpacesForWindows` confirmed the window's new Space.
- Titlebar hit-tests:
  - Standard AppKit window, 8 pt below the top edge: `AXWindow`. Safe to grab.
  - Chrome/Brave at 25 %, 50 % and 75 % of the width: `AXGroup` or `AXUnknown`. Safe, it's the tab-strip background.
  - Chrome/Brave at the traffic lights + 80 pt: `AXButton`. Must be rejected.
- A listen-only `CGEventTap` (`cgSessionEventTap`) sees a synthetic ⌥N keyDown with `maskAlternate`, even though the native hotkey fires too.
- **An ⌥N posted during a Space animation is silently dropped.** ⌥2 sent 1 s after a throw did nothing. The same event sent a bit later switched.
- `activateSettings` exists under `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/`.
- Finder's desktop shows up as an AX window with no subrole, a non-settable size and a full-screen frame. It has to be excluded.

## What this means for the code
- **SpaceMover.** After a throw, wait until the active Space is the target and has settled (about 300–500 ms) before releasing the mouse or switching again. Presses that arrive mid-transition are ignored or queued.
- **Missing-Space notice.** Count only `type == 0` Spaces on the display. Desktop N is the Nth user Space in array order, never the raw `ManagedSpaceID`.
- **E2E harness.** After any Space switch, poll `CGSGetActiveSpace` and wait until it's been stable for 500 ms before the next keystroke.
