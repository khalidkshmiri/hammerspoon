-- Auto-reloads when any file in ~/.hammerspoon/ is saved

-- ── Auto-reload on save ───────────────────────────────────────────────────────
if _G.configWatcher then _G.configWatcher:stop() end
if _G.reloadTimer then _G.reloadTimer:stop() end
_G.configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function()
    if _G.reloadTimer then _G.reloadTimer:stop() end
    _G.reloadTimer = hs.timer.doAfter(0.5, hs.reload)
end):start()
hs.alert.show("Config loaded")

-- ── Modules ───────────────────────────────────────────────────────────────────
require("modules.window_manager")
require("modules.brightness_manager")
