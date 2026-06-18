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
- Clipboard ring: keeps the last N text clips, Hyper+V opens a searchable picker.
- Middle-click a Dock icon to quit the app; middle-click a menu-bar icon to quit its app.
- Shift + scroll for horizontal scrolling anywhere.
- Brightness managers for external (BetterDisplay CLI) and built-in displays, with a
  daily reset of built-in brightness.
- `hs` command-line interface enabled via `hs.ipc`.
- Auto-reload of the config on `.lua` save, with per-module error alerts.

### Changed

- Cmd+Opt+V passes through to Finder so cut-paste (move) of files still works.
- Removed quit-notification alerts for Dock and menu-bar quit actions.

### Fixed

- Hyper + drag no longer resizes instead of moving (or triggers Hide Others) after a
  Space switch.
- Resize uses a 60fps timer instead of a canvas overlay to eliminate lag in slow apps.
