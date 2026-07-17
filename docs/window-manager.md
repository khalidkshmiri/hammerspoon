# Window Manager

Mouse-driven window management for macOS via Hammerspoon. This module owns three
interaction families:

1. Hyper + left-drag to move a window or resize it from an edge.
2. Hyper + double-click to maximize or restore.
3. Plain drag / double-click on a maximized window's title bar to restore or
   toggle, mimicking native title-bar behavior.

## Architecture

`modules/window_manager.lua` installs one global `hs.eventtap` for left/right
mouse and scroll events, plus a `flagsChanged` watcher that tracks whether Hyper
is effectively held. It keeps just enough state in Lua to distinguish:

- move drags vs resize drags
- Hyper gestures vs plain title-bar gestures
- windows we maximized ourselves vs windows the app/macOS resized some other way

Long-lived globals are torn down at the top of the module so reloads do not leak
duplicate taps or watchers.

## Data Model

- `savedFrames[winId] = { pre = <frame>, max = <frame> }`
  Stores the pre-maximize frame and the exact maximized frame this module set.
- `dragState`
  Tracks the active move/resize gesture.
- `pendingPlainDrag`
  Defers interception of plain top-bar clicks until they become an actual drag.
- `scrollTarget`
  Coalesces Hyper+scroll resize updates onto a timer so slow apps do not block
  the event tap. Scroll deltas resize at 1.0 px per delta, independently from
  the raw-pixel speed of a mouse drag.

## Flows

### Hyper + left-drag

- If the pointer is inside the edge margin, start resize mode.
- Otherwise arm move mode.
- Move mode clamps the full window to the usable frame of the screen under the
  pointer, so Hyper-drag cannot leave part of a normally sized window off-screen.
- When a resize edge is already at a display boundary, pushing outward switches
  to the opposite available edge, so the gesture can continue growing inward.
- If the window was previously maximized by this module, the first drag restores
  the saved frame while keeping the pointer anchored proportionally inside it.

### Hyper + double-click

- First click stores `lastClick`.
- Second click within `DOUBLE_CLICK_INTERVAL` toggles maximize/restore.

### Plain title-bar drag / double-click

- Only applies to windows this module previously maximized, except plain
  double-click which can maximize any standard window.
- The module first checks a geometric top strip, then uses
  `hs.axuielement.systemElementAtPosition()` to avoid treating toolbar buttons
  and other real controls as title-bar clicks.
- Plain double-click and plain drag both use the same rule: the pointer must be
  inside the top strip and AX must not report a concrete interactive control
  such as a button, menu button, search field, or text field.
- Single clicks pass through; interception only happens for the matching
  double-click or after movement confirms a drag.

## Bindings

| Action | Gesture |
| --- | --- |
| Move window | Hyper + left-drag away from edges |
| Resize window from edge | Hyper + left-drag near edge |
| Resize window from nearest corner | Hyper + right-drag |
| Resize window from nearest corner | Hyper + two-finger scroll |
| Maximize / restore | Hyper + double-click |
| Restore maximized window by dragging | Plain drag on top bar |
| Maximize / restore from top bar | Plain double-click on top bar |

## Mistakes & Gotchas

- Geometry alone is not enough for the top bar. Many apps place actionable
  controls inside the same visual strip as the title bar, so a pure
  `TITLE_BAR_HEIGHT` check can misfire and resize/maximize when the user really
  double-clicked a toolbar button.
- `hs.axuielement` is best-effort. Some apps expose incomplete accessibility
  trees, so AX hit-testing is a guardrail, not a perfect source of truth. This
  module only blocks confirmed interactive controls; unknown/container hits are
  allowed so normal title-bar double-click still works in toolbar-heavy apps.
- `DOUBLE_CLICK_INTERVAL` is intentionally short. Raising it makes accidental
  window toggles much more likely when you click a top-bar control twice.
- The click event's own modifier flags can lag behind Karabiner's synthetic
  Hyper delivery. The separate `flagsChanged` watcher is there to avoid random
  fallthrough into native macOS behavior.

## Debugging Playbook

1. Reload the config: `hs -c 'hs.reload()'`.
2. Syntax-check the file quickly with `luac -p modules/window_manager.lua`.
3. If top-bar behavior is wrong in a specific app, inspect the AX role under the
   cursor with a one-off `hs -c` snippet using `hs.axuielement.systemElementAtPosition`.
4. If live behavior still looks inconsistent, read the Hammerspoon console for
   swallowed errors because the wider config loads modules behind `pcall`.
