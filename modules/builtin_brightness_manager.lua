package.loaded["modules.builtin_brightness_manager"] = nil

if _G.builtinBrightnessMidnightTimer then _G.builtinBrightnessMidnightTimer:stop() end
if _G.builtinBrightnessWakeWatcher then _G.builtinBrightnessWakeWatcher:stop() end

-- No built-in backlight to control (e.g. desktop Mac) — nothing to do.
if hs.brightness.get() == nil then return end

local DEFAULT_BRIGHTNESS = 100
local SETTINGS_KEY = "builtinBrightnessLastReset"

local function today()
    return os.date("%Y-%m-%d")
end

-- Reset built-in display brightness to 100% if it hasn't been done yet today.
-- Manual changes made during the day are left alone until the next reset.
local function resetIfNewDay()
    local lastReset = hs.settings.get(SETTINGS_KEY)
    if lastReset ~= today() then
        hs.brightness.set(DEFAULT_BRIGHTNESS)
        hs.settings.set(SETTINGS_KEY, today())
    end
end

-- Run once on load/reload, in case it's a new day.
resetIfNewDay()

-- Daily reset at midnight.
_G.builtinBrightnessMidnightTimer = hs.timer.doAt("00:00", "1d", function()
    hs.brightness.set(DEFAULT_BRIGHTNESS)
    hs.settings.set(SETTINGS_KEY, today())
end)

-- Catch the case where the Mac was asleep through midnight: check on wake too.
_G.builtinBrightnessWakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
        resetIfNewDay()
    end
end):start()
