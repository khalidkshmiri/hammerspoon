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
for _, mod in ipairs({
    "modules.window_manager",
    "modules.brightness_manager",
    "modules.builtin_brightness_manager",
    "modules.paste_manager",
    "modules.click_quit",
    "modules.clipboard_manager",
    "modules.horizontal_scroll",
    "modules.app_rules",
}) do
    local ok, err = pcall(require, mod)
    if not ok then hs.alert.show("Error loading " .. mod .. ":\n" .. tostring(err)) end
end

hs.alert.show("Config loaded")
