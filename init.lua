-- ── Auto-reload on save ───────────────────────────────────────────────────────
-- Watch hs.configdir (the real resolved path) rather than ~/.hammerspoon/ so that
-- FSEvents fires correctly when files are symlinked from another directory.
if _G.configWatcher then _G.configWatcher:stop() end
if _G.reloadTimer   then _G.reloadTimer:stop()   end
_G.configWatcher = hs.pathwatcher.new(hs.configdir, function(files)
    local needsReload = false
    for _, f in ipairs(files) do
        if f:sub(-4) == ".lua" then needsReload = true; break end
    end
    if not needsReload then return end
    if _G.reloadTimer then _G.reloadTimer:stop() end
    _G.reloadTimer = hs.timer.doAfter(0.3, hs.reload)
end):start()

-- ── Command-line interface ────────────────────────────────────────────────────
-- Registers the IPC message port so the `hs` CLI (symlinked in /opt/homebrew/bin)
-- can send Lua to this running instance.
require("hs.ipc")

-- ── Modules ───────────────────────────────────────────────────────────────────
local function load(mod)
    local ok, err = pcall(require, mod)
    if not ok then hs.alert.show("Error loading " .. mod .. ":\n" .. tostring(err)) end
end

load("modules.window_manager")
load("modules.brightness_manager")
load("modules.builtin_brightness_manager")
load("modules.paste_manager")
load("modules.dock_quit")

hs.alert.show("Config loaded")
