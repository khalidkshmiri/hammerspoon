-- Auto-reloads when any file in ~/.hammerspoon/ is saved

-- ── Auto-reload on save ───────────────────────────────────────────────────────
if _G.configWatcher then _G.configWatcher:stop() end
_G.configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", hs.reload):start()
hs.alert.show("Config loaded")

-- ── Modules ───────────────────────────────────────────────────────────────────
require("modules.window_manager")
