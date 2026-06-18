# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Mouse-driven window management: Hyper + drag to move/resize, Hyper + double-click
  to toggle maximize/restore, drag the title bar to restore.
- App layout auto-restore: a saved set of apps is restored into a persistent desktop
  Space on launch.
- Plain-paste manager: Cmd+V pastes without formatting, Cmd+Opt+V keeps formatting.
- Clipboard manager: Hyper+V toggles a native-style, keyboard-driven history panel.
  Captures text, rich text, images, files/paths and URLs (colour-coded, with image
  thumbnails) and persists across reboots. Bindings: ↩ paste into the active window ·
  ⌘↩ paste & keep the panel open · ⌘C copy for manual paste · ⌘Y Quick Look ·
  ⌘S save to Desktop · ⌘R show in Finder · ⌘⇧S share · ⌘⌫ delete · ⌘⇧⌫ clear all ·
  type to search · `?` controls overlay · esc to close.
- Numbered quick-paste: the panel numbers the first 10 rows (1–9, 0); pressing a digit
  pastes that item into the active window and keeps the panel open, without changing
  history order — so you can fire off several clips in sequence.
- Middle-click a Dock icon to quit the app; middle-click a menu-bar icon to quit its app.
- Shift + scroll for horizontal scrolling anywhere.
- Brightness managers for external (BetterDisplay CLI) and built-in displays, with a
  daily reset of built-in brightness.
- `hs` command-line interface enabled via `hs.ipc`.
- Auto-reload of the config on `.lua` save, with per-module error alerts.

### Changed

- Cmd+Opt+V passes through to Finder so cut-paste (move) of files still works.
- Removed quit-notification alerts for Dock and menu-bar quit actions.
- Replaced the text-only clipboard ring (hs.chooser) with the rich clipboard manager
  above. Its keyboard is driven by a global eventtap that's live only while the panel
  shows, since a borderless webview can't take key focus.

### Fixed

- Hyper + drag no longer resizes instead of moving (or triggers Hide Others) after a
  Space switch.
- Resize uses a 60fps timer instead of a canvas overlay to eliminate lag in slow apps.
- Clipboard panel: Esc now dismisses it immediately, without first clicking the window.
- Clipboard panel: Hyper+V again now dismisses the panel (toggle) instead of re-rendering.
- Clipboard panel: keep-open pastes (numbered quick-paste and ⌘↩) now actually paste —
  the panel's own eventtap was swallowing the synthetic Cmd+V while it stayed open.
