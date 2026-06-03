package.loaded["modules.brightness_manager"] = nil

if _G.brightnessCaffeinateWatcher then _G.brightnessCaffeinateWatcher:stop() end
if _G.brightnessScreenWatcher then _G.brightnessScreenWatcher:stop() end

local BUILTIN_NAMES = { ["Built-in Retina Display"] = true, ["Color LCD"] = true }
local BETTERDISPLAY = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

local function externalScreen()
    for _, screen in ipairs(hs.screen.allScreens()) do
        if not BUILTIN_NAMES[screen:name()] then
            return screen
        end
    end
    return nil
end

local function targetBrightness()
    local h = tonumber(os.date("%H"))
    local m = tonumber(os.date("%M"))
    local mins = h * 60 + m
    if mins >= 7*60 and mins < 18*60 then
        return 0.8
    elseif mins >= 18*60 and mins < 21*60 + 30 then
        return 0.6
    else
        return 0.4
    end
end

local function applyBrightness()
    local screen = externalScreen()
    if not screen then return end
    local brightness = targetBrightness()
    local name = screen:name()
    local brightnessStr = string.format("%.1f", brightness)
    hs.task.new(BETTERDISPLAY, function(code, stdout, stderr)
        if code ~= 0 then
            hs.alert.show("Brightness error: " .. (stderr ~= "" and stderr or stdout))
        end
    end, { "set", string.format("-name=%s", name), string.format("-brightness=%s", brightnessStr) }):start()
end

_G.brightnessCaffeinateWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
        applyBrightness()
    end
end):start()

_G.brightnessScreenWatcher = hs.screen.watcher.new(applyBrightness):start()

applyBrightness()
