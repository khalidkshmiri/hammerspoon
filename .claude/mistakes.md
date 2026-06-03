# Mistakes

## window_manager.lua — broke drag reliability, then failed to diagnose it

**Session 1 (initial diagnosis)**
Diagnosed several theoretical reliability issues without checking git history first.
Proposed the `visibleApps`/`pendingUnhide` mechanism to handle macOS "Option hides other apps"
behavior — a problem that didn't exist in the original working code.

**Session 2 (attempted fix)**
Added `pendingUnhide` at module level to replace the `visibleApps` mechanism that was already
in the uncommitted working tree. This kept the same root cause: `hs.application.runningApplications()`
called on every Hyper mouse-down. That IPC call takes 50–200ms, blocking the eventtap callback
long enough for macOS to drop subsequent mouse events — exactly the unreliable drag symptom.

**What should have happened**
Check `git log` and `git diff` against the last known-working commit *before* diagnosing or
changing anything. The breaking change was in the uncommitted working tree, not in any commit.
`git diff HEAD` would have shown the `visibleApps` addition immediately.

**Rule**
When the user says something "used to work": read git history first, diff against the last
working commit, identify what changed. Do not theorize and do not add new mechanisms before
understanding what broke.

---

## init.lua — pathwatcher watching symlink path instead of real path

`~/.hammerspoon/init.lua` and `~/.hammerspoon/modules` are symlinks into
`~/Developer/hammerspoon/`. The pathwatcher was watching `~/.hammerspoon/` using
`os.getenv("HOME") .. "/.hammerspoon/"`. FSEvents fires on real paths, not symlink paths,
so saving any file in the project directory never triggered a reload.

**What should have happened**
Check `ls -la ~/.hammerspoon` before assuming the watcher path is correct. A one-second
inspection would have shown the symlinks. The fix is `hs.configdir` which Hammerspoon
resolves to the real directory automatically.

**Rule**
When a file watcher isn't firing, check whether the watched path is a symlink before
anything else.
