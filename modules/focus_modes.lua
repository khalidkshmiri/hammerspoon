package.loaded["modules.focus_modes"] = nil

-- ── Focus-mode-driven config ──────────────────────────────────────────────────
-- macOS doesn't give Hammerspoon a clean, reliable way to READ the current Focus,
-- so we let Focus tell us: a Shortcuts personal automation ("When [Focus] turns
-- On/Off → Run shell script") calls the `hs` CLI, which runs onFocus() here.
--
-- One-time setup per Focus, in the Shortcuts app (Automation tab):
--   Trigger : "When School/Study turns On"   (and a second one for "turns Off")
--   Action  : Run Shell Script →
--               /opt/homebrew/bin/hs -c 'onFocus("school", true)'
--             (use false for the "turns Off" automation)
--   Turn OFF "Ask Before Running".
--
-- Then edit the ACTIONS table below: each entry runs when that Focus turns on, and
-- its optional `off` runs when it turns off. Everything here is just Lua, so a Focus
-- can do anything Hammerspoon can: set volume/brightness, quit or launch apps, send
-- a Telegram message, toggle Wi-Fi, etc. Examples are commented — uncomment/edit.

-- Helpers you can call from the actions below.
local function setVolume(pct) hs.audiodevice.defaultOutputDevice():setVolume(pct) end
local function mute(on)       hs.audiodevice.defaultOutputDevice():setMuted(on)   end
local function quit(bundleID) local a = hs.application.get(bundleID); if a then a:kill() end end
local function launch(bundleID) hs.application.launchOrFocusByBundleID(bundleID) end

-- key = the string you pass from Shortcuts. on()/off() are run on enable/disable.
local ACTIONS = {
    school = {
        on = function()
            -- mute(true)
            -- quit("com.spotify.client")
            -- quit("com.tinyspeck.slackmacgap")
            -- (dim the display via whatever your brightness_manager exposes)
        end,
        off = function()
            -- mute(false)
        end,
    },
    work = {   -- "Work/Barber"
        on  = function() end,
        off = function() end,
    },
    sleep = {
        on  = function()
            -- mute(true)
            -- for _, a in ipairs(hs.application.runningApplications()) do ... end
        end,
        off = function() end,
    },
    gym     = { on = function() end, off = function() end },
    driving = { on = function() end, off = function() end },
    dnd     = { on = function() end, off = function() end },  -- Personal/DND
}

-- Called from Shortcuts: onFocus("school", true) on enable, false on disable.
function _G.onFocus(mode, enabled)
    local a = ACTIONS[mode]
    if not a then
        hs.alert.show("focus_modes: unknown mode '" .. tostring(mode) .. "'")
        return
    end
    local fn = enabled and a.on or a.off
    if fn then
        local ok, err = pcall(fn)
        if not ok then hs.alert.show("focus_modes error: " .. tostring(err)) end
    end
    hs.alert.show("Focus: " .. mode .. (enabled and " on" or " off"))
end
