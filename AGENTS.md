# AGENTS.md

Instructions for any AI agent (Codex, Claude, etc.) working in this repo.
`CLAUDE.md` is the full guide — read it first. This file highlights the rules
that matter most.

## Keep documentation up to date

- Every module has a deep-dive doc at `docs/<module-name>.md` (lowercase-hyphens),
  following `docs/clipboard-manager.md`: architecture → data model → flows → full
  bindings table → **Mistakes & gotchas** (from real bugs) → debugging playbook.
- **Update the docs in the same commit as the code.** Adding or meaningfully
  changing a module means creating or updating its `docs/*.md` in that same
  change. A doc that has drifted out of date is worse than none.
- Record newly discovered gotchas / API surprises in the module's
  "Mistakes & gotchas" section so they aren't rediscovered the hard way.
- Link each module doc from its bullet in the **Layout** section of `CLAUDE.md`.
- Modules still missing docs (backfill in the same style): `window_manager`,
  `app_rules`, `paste_manager`, `dock_quit`, `menubar_quit`, `horizontal_scroll`,
  `brightness_manager`, `builtin_brightness_manager`.

## Working in this repo

- **Reload after a change:** `hs -c 'hs.reload()'`.
- **Verify in the live instance:** `hs -c '<lua>'`. Relaunch the Hammerspoon app
  first if you get a message-port error.
- Errors are often swallowed by `pcall`/`xpcall` guards — when something silently
  doesn't work, read the console:
  `hs -c 'print(hs.console.getConsole())' | tr -d '\000' | grep -iE 'fail|error|:[0-9]+:'`.
- When something "used to work" and broke, check `git log` / `git diff` before
  theorizing or adding code. macOS/Hammerspoon API return shapes change between
  versions.

## Code style

- Comment the **why** (constraints, gotchas, rejected alternatives), not the what.
- Surgical changes: touch only what the task needs; match the existing module
  style; each module either `return`s a table or self-registers its taps/hotkeys.
- Add a teardown line at the top of a module for any new persistent
  tap/timer/hotkey stored on `_G`, or reloads leak duplicates.
