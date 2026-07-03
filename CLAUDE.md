# CLAUDE.md

Personal [Hammerspoon](https://www.hammerspoon.org) configuration (Lua) for macOS:
mouse-driven window management plus a set of keyboard/input/automation shortcuts.

## Layout

- **`init.lua`** — entry point. Does three things:
  1. Auto-reload watcher — watches `hs.configdir` (the resolved path, so it works
     when `init.lua` is symlinked from this repo) and calls `hs.reload()` ~0.3s
     after any `.lua` file changes.
  2. `require("hs.ipc")` — registers the IPC message port so the `hs` CLI can send
     Lua to the running instance.
  3. Loads each module via a `pcall`-wrapped `load("modules.X")` helper, so one
     broken module shows an alert instead of taking down the whole config.
- **`modules/`** — one feature per file:
  - `window_manager.lua` — Hyper + drag to move/resize a window; Hyper + double-click
    to toggle maximize/restore. The core feature (see README).
    **Deep dive + gotchas: [`docs/window-manager.md`](docs/window-manager.md).**
  - `app_rules.lua` — auto-restores a saved app layout into a persistent desktop
    Space when those apps launch. Layouts are keyed by a signature of the attached
    screens (MacBook-alone vs docked are separate), so capture once per setup with
    `hs -c "captureLayout()"`; restore picks the matching layout automatically.
  - `paste_manager.lua` — Cmd+V pastes WITHOUT formatting (strips rich text);
    Cmd+Opt+V keeps formatting. Files/images pass through unchanged.
  - `clipboard_manager.lua` — Hyper+V toggles a native-style, keyboard-driven
    history panel (text/rich/image/file/URL, persists across reboots). Keyboard is
    driven by a global `hs.eventtap` that's live only while the panel shows, because
    a borderless webview can't take key focus. Bindings: ↩ paste · ⌘↩ paste+keep
    open · click row to select, click selected row to paste · hold ⌘ shows 1-9
    badges, ⌘1-9 pastes that item (keeps open) · ⌘C copy · ⌘Y Quick Look (toggle) ·
    space preview (toggle) · scroll wheel scrolls history · ⌘S save to Desktop ·
    ⌘R reveal · ⌘⌫ delete · ⌘⇧⌫ clear all · `/` or `?` compact actions sheet
    (toggle) · esc close.
    **Deep dive + gotchas: [`docs/clipboard-manager.md`](docs/clipboard-manager.md).**
  - `dock_quit.lua` — middle-click a Dock icon to quit that app (≡ ⌘Q).
  - `menubar_quit.lua` — middle-click a third-party menu-bar icon to quit its app.
  - `horizontal_scroll.lua` — hold Shift while scrolling to scroll horizontally.
  - `brightness_manager.lua` / `builtin_brightness_manager.lua` — brightness control
    (external displays / built-in display).

## Conventions

- Each module is loaded by `init.lua` and either `return`s a table or self-registers
  its event taps/hotkeys on load. To add a feature, drop a file in `modules/` and add
  a `load("modules.X")` line in `init.lua`.
- The trigger for window/clipboard actions is the **Hyper key**
  (Cmd+Ctrl+Opt+Shift held together). Configurable via `MODIFIER` near the top of the
  relevant module.

## Working in this repo

- **Reload after a change:** `hs -c 'hs.reload()'`.
- **Run Lua in the live instance** (for verification): `hs -c '<lua>'`. If you get a
  message-port error, relaunch the Hammerspoon app first.
- When something "used to work" and broke, check `git log`/`git diff` before
  theorizing or adding code.

## Documentation (keep it current)

- Every module has a deep-dive doc at `docs/<module-name>.md` (lowercase-hyphens),
  following the pattern set by [`docs/clipboard-manager.md`](docs/clipboard-manager.md):
  architecture → data model → flows → full bindings table → **Mistakes & gotchas**
  (drawn from real bugs) → debugging playbook.
- **Update docs in the same commit as the code.** When you add or meaningfully
  change a module, create or update its `docs/*.md` alongside the change — a doc
  that drifts out of date is worse than none. Add newly discovered gotchas/API
  surprises to the module's "Mistakes & gotchas" section.
- Link each module doc from its bullet in the **Layout** section above.
- Modules still missing docs: `window_manager`, `app_rules`, `paste_manager`,
  `dock_quit`, `menubar_quit`, `horizontal_scroll`, `brightness_manager`,
  `builtin_brightness_manager` — backfill in the clipboard-manager style.

## Requirements

- Hammerspoon installed and running, with Accessibility permission granted
  (`System Settings → Privacy & Security → Accessibility`).
- The `hs` CLI requires `hs.ipc` (already loaded by `init.lua`).
