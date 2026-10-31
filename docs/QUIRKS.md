# macOS quirks: verified behaviour on macOS 27.2 (arm64)

Spike scripts were run on 2026-10-31. Every entry here is observed on this machine, not assumed.

## Spike results
| # | Check | Result |
|---|---|---|
| S1 | `AXIsProcessTrusted()` from the terminal | true (the terminal already has Accessibility) |
| S2 | `_AXUIElementGetWindow` via `dlsym(RTLD_DEFAULT)` | resolves, and returns the same id as `NSWindow.windowNumber` |
| S3 | SkyLight read-only: `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`, `CGSManagedDisplayGetCurrentSpace` (and the `SLS*` aliases) | all resolve and work |
| S4 | `CGSCopyManagedDisplaySpaces` shape | one dict per display, with `Display Identifier` (UUID), `Current Space.ManagedSpaceID` and `Spaces[]` (`ManagedSpaceID`, `type`: 0 = user, 4 = fullscreen). User Space ids here are 4, 5, 6 and 8: **not contiguous and not equal to the index**. |
| S5 | **Drag trick** (mouse-down on the titlebar, then ⌥1 posted at `.cghidEventTap`, then mouse-up) | **works**. The window moved to the target Space and the active Space changed 373 ms after mouse-down. `CGSCopySpacesForWindows` confirms the window is on the new Space. |
| S6 | Titlebar hit-test at y = top + 8, standard AppKit window | `AXWindow`: a safe grab point |
| S7 | Chrome/Brave titlebar hit-test at 25/50/75% of the width | `AXGroup/AXUnknown`: a safe grab point (draggable tab-strip area) |
| S8 | Chrome/Brave hit-test at traffic lights + 80 pt | `AXButton`: **must reject** |
| S9 | Listen-only `CGEventTap` (`cgSessionEventTap`) | sees synthetic ⌥N keyDown with `maskAlternate`, even though the native symbolic hotkey also fires |
| S10 | **A ⌥N posted while a Space transition animation is still running is silently dropped** | observed: ⌥2 sent 1 s after the throw did nothing, and the same event a little later switched. |
| S11 | `activateSettings` at `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/` | present |
| S12 | Finder's desktop window | appears in AX windows with no subrole, a non-settable size and a full-screen frame. Must be excluded (the subrole isn't standard). |

## Design consequences
- **SpaceMover.** After the throw, wait until the active Space equals the target *and* the transition has settled (about 300–500 ms) before releasing the mouse or issuing another switch. Hotkey handling must ignore or queue presses that arrive while a transition is in flight.
- **Missing-Space notice.** Count only `type == 0` Spaces on the display. Index N maps to the N-th user Space in array order, never to the raw `ManagedSpaceID`.
- **E2E harness.** After any Space switch, poll `CGSGetActiveSpace` and wait for the transition to settle (no change for 500 ms) before the next keystroke.
