package.loaded["modules.brightness_manager"] = nil

if _G.brightnessCaffeinateWatcher then _G.brightnessCaffeinateWatcher:stop() end
if _G.brightnessScreenWatcher then _G.brightnessScreenWatcher:stop() end

local BUILTIN_NAMES = { ["Built-in Retina Display"] = true, ["Color LCD"] = true }
local BETTERDISPLAY = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

if not hs.fs.attributes(BETTERDISPLAY) then
    hs.alert.show("BetterDisplay CLI not found — brightness manager disabled")
    return
end

-- Tracks the last brightness the script set and which period it was set in.
-- Used to detect manual adjustments: if current brightness differs from lastSet.brightness
-- and the period hasn't changed, we assume the user adjusted manually and leave it alone.
local lastSet = { brightness = nil, period = nil }
local pendingBrightness = false

local function externalScreen()
    for _, screen in ipairs(hs.screen.allScreens()) do
        if not BUILTIN_NAMES[screen:name()] then
            return screen
        end
    end
    return nil
end

local function currentPeriod()
    local mins = tonumber(os.date("%H")) * 60 + tonumber(os.date("%M"))
    if mins >= 7*60 and mins < 18*60 then return "day"
    elseif mins >= 18*60 and mins < 21*60 + 30 then return "evening"
    else return "night" end
end

local function targetBrightness()
    local p = currentPeriod()
    if p == "day" then return 0.8
    elseif p == "evening" then return 0.6
    else return 0.4 end
end

local function setBrightness(name, brightness)
    local brightnessStr = string.format("%.1f", brightness)
    -- Snapshot built-in brightness before running BetterDisplay — it can
    -- inadvertently change the internal display as a side effect.
    local builtinBefore = hs.brightness.get()
    pendingBrightness = true
    hs.task.new(BETTERDISPLAY, function(code, stdout, stderr)
        pendingBrightness = false
        if code == 0 then
            lastSet.brightness = brightness
            lastSet.period = currentPeriod()
            -- Restore built-in brightness if BetterDisplay touched it.
            local builtinAfter = hs.brightness.get()
            if builtinAfter ~= builtinBefore then
                hs.brightness.set(builtinBefore)
            end
        else
            hs.alert.show("Brightness error: " .. (stderr ~= "" and stderr or stdout))
        end
    end, { "set", string.format("-name=%s", name), string.format("-brightness=%s", brightnessStr) }):start()
end

local function applyBrightness(respectManual)
    if pendingBrightness then return end
    local screen = externalScreen()
    if not screen then return end
    local name = screen:name()
    local period = currentPeriod()
    local target = targetBrightness()

    -- Always apply if period changed or this is the first run
    if not respectManual or lastSet.period ~= period or lastSet.brightness == nil then
        setBrightness(name, target)
        return
    end

    -- Same period: read current brightness to check for manual adjustment
    pendingBrightness = true
    hs.task.new(BETTERDISPLAY, function(code, stdout, stderr)
        pendingBrightness = false
        if code ~= 0 then return end
        local current = tonumber(stdout:match("^%s*([%d%.]+)"))
        if current == nil then return end  -- unparseable output, skip
        if math.abs(current - lastSet.brightness) > 0.05 then
            return -- user manually adjusted, leave it alone
        end
        setBrightness(name, target)
    end, { "get", string.format("-name=%s", name), "-brightness" }):start()
end

_G.brightnessCaffeinateWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
        applyBrightness(true)
    end
end):start()

_G.brightnessScreenWatcher = hs.screen.watcher.new(function()
    applyBrightness(false)
end):start()

applyBrightness(false)
