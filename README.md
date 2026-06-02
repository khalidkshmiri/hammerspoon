# hammerspoon

Mouse-driven window management for macOS using [Hammerspoon](https://www.hammerspoon.org). Move, resize, maximize, and restore windows without touching the title bar — just hold Hyper and use your mouse.

## Features

- **Move** — Hyper + drag anywhere inside a window to move it
- **Resize** — Hyper + drag near any edge or corner to resize from that side
- **Maximize** — Hyper + double-click a window to fill the screen
- **Restore** — Hyper + double-click again (or drag the title bar) to return to the pre-maximize size
- **Auto-reload** — saves to `~/.hammerspoon/` reload the config instantly

## Requirements

- [Hammerspoon](https://www.hammerspoon.org) installed and running
- Accessibility permission granted to Hammerspoon (`System Settings → Privacy & Security → Accessibility`)

## Modifier key

By default the trigger is the **Hyper key** (Left Cmd + Left Ctrl + Left Opt + Left Shift held simultaneously), but you can use any combination. Near the top of `init.lua`, change the `MODIFIER` table:

```lua
-- Hyper (default):
local MODIFIER = { cmd = true, ctrl = true, alt = true, shift = true }

-- Lighter combos:
local MODIFIER = { cmd = true, ctrl = true }             -- Cmd + Ctrl
local MODIFIER = { cmd = true, ctrl = true, alt = true } -- Cmd + Ctrl + Opt
```

If you use [Karabiner-Elements](https://karabiner-elements.pqrs.org) to map Caps Lock (or another key) to all four modifiers at once, the script handles the small timing gap that remappers can introduce between the click event and the modifier flags.

## Installation

**Option A — direct copy:**
```bash
cp init.lua ~/.hammerspoon/init.lua
```

**Option B — symlink (if you manage dotfiles):**
```bash
ln -s /path/to/hammerspoon/init.lua ~/.hammerspoon/init.lua
```

Then reload Hammerspoon (`Cmd+R` in the Hammerspoon console, or click the menu bar icon → Reload Config). You should see a "Config loaded" alert.

## Controls

| Action | How |
|---|---|
| Move window | Hyper + drag (interior of window) |
| Resize window | Hyper + drag (within ~20px of any edge or corner) |
| Maximize | Hyper + double-click |
| Restore to pre-maximize size | Hyper + double-click again |
| Restore by dragging | Drag the title bar of a maximized window |

## Configuration

All tuneable constants are at the top of `init.lua`:

| Constant | Default | Description |
|---|---|---|
| `MODIFIER` | `{ cmd, ctrl, alt, shift }` | Modifier keys that must be held to activate window management |
| `RESIZE_MARGIN` | `20` px | Distance from edge where modifier+drag triggers resize instead of move |
| `DOUBLE_CLICK_INTERVAL` | `0.35` s | Max time between two Hyper+clicks to count as a double-click |
| `TITLE_BAR_HEIGHT` | `32` px | Height of the title bar intercept zone for restoring maximized windows |
| `MIN_WIN_W` / `MIN_WIN_H` | `200` / `100` px | Minimum window size enforced during resize |
| `ANIMATE_DURATION` | `0.2` s | Animation duration for maximize and restore transitions |

## License

MIT
