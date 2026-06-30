package.loaded["modules.brightness_manager"] = nil

if _G.brightnessCaffeinateWatcher then _G.brightnessCaffeinateWatcher:stop() end
if _G.brightnessScreenWatcher then _G.brightnessScreenWatcher:stop() end
if _G.brightnessApplyTimer then _G.brightnessApplyTimer:stop() end

local BUILTIN_NAMES = { ["Built-in Retina Display"] = true, ["Color LCD"] = true }
local BETTERDISPLAY = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
local STABILIZE_DELAY = 3
local RETRY_DELAY = 2
local MAX_RETRIES = 3

if not hs.fs.attributes(BETTERDISPLAY) then
    hs.alert.show("BetterDisplay CLI not found — brightness manager disabled")
    return
end

-- Tracks the last brightness the script set and which period it was set in.
-- Used to detect manual adjustments: if current brightness differs from lastSet.brightness
-- and the period hasn't changed, we assume the user adjusted manually and leave it alone.
local lastSet = { brightness = nil, period = nil }
local pendingBrightness = false
local applyGeneration = 0

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

local function runBetterDisplay(args, callback)
    hs.task.new(BETTERDISPLAY, function(code, stdout, stderr)
        callback(code, stdout or "", stderr or "")
    end, args):start()
end

local function setBrightness(screen, brightness, suppressAlert, callback)
    local name = screen and screen:name()
    if not name then
        callback(false, "Display not available")
        return
    end
    local brightnessStr = string.format("%.1f", brightness)
    -- Snapshot built-in brightness before running BetterDisplay — it can
    -- inadvertently change the internal display as a side effect.
    local builtinBefore = hs.brightness.get()
    pendingBrightness = true
    runBetterDisplay({ "set", string.format("-name=%s", name), string.format("-brightness=%s", brightnessStr) }, function(code, stdout, stderr)
        pendingBrightness = false
        if code == 0 then
            lastSet.brightness = brightness
            lastSet.period = currentPeriod()
            -- Restore built-in brightness if BetterDisplay touched it.
            local builtinAfter = hs.brightness.get()
            if builtinAfter ~= builtinBefore then
                hs.brightness.set(builtinBefore)
            end
            callback(true)
        else
            local msg = (stderr ~= "" and stderr or stdout)
            if not suppressAlert then hs.alert.show("Brightness error: " .. msg) end
            callback(false, msg)
        end
    end)
end

local function getBrightness(screen, callback)
    local name = screen and screen:name()
    if not name then
        callback(nil, "Display not available")
        return
    end
    pendingBrightness = true
    runBetterDisplay({ "get", string.format("-name=%s", name), "-brightness" }, function(code, stdout, stderr)
        pendingBrightness = false
        if code ~= 0 then
            callback(nil, (stderr ~= "" and stderr or stdout))
            return
        end
        callback(tonumber(stdout:match("^%s*([%d%.]+)")), nil)
    end)
end

local function applyBrightness(respectManual, generation, attempt)
    if pendingBrightness then return end
    local screen = externalScreen()
    if not screen then return end
    local period = currentPeriod()
    local target = targetBrightness()
    local finalAttempt = attempt >= MAX_RETRIES

    local function retry()
        if generation ~= applyGeneration or finalAttempt then return false end
        hs.timer.doAfter(RETRY_DELAY, function()
            if generation == applyGeneration then
                applyBrightness(respectManual, generation, attempt + 1)
            end
        end)
        return true
    end

    -- Always apply if period changed or this is the first run
    if not respectManual or lastSet.period ~= period or lastSet.brightness == nil then
        setBrightness(screen, target, not finalAttempt, function(ok)
            if not ok then retry() end
        end)
        return
    end

    -- Same period: read current brightness to check for manual adjustment
    getBrightness(screen, function(current)
        if current == nil then
            retry()
            return
        end
        if math.abs(current - lastSet.brightness) > 0.05 then
            return -- user manually adjusted, leave it alone
        end
        setBrightness(screen, target, not finalAttempt, function(ok)
            if not ok then retry() end
        end)
    end)
end

local function scheduleApply(respectManual)
    applyGeneration = applyGeneration + 1
    local generation = applyGeneration
    if _G.brightnessApplyTimer then _G.brightnessApplyTimer:stop() end
    _G.brightnessApplyTimer = hs.timer.doAfter(STABILIZE_DELAY, function()
        if generation == applyGeneration then
            applyBrightness(respectManual, generation, 1)
        end
    end)
end

_G.brightnessCaffeinateWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock then
        scheduleApply(true)
    end
end):start()

_G.brightnessScreenWatcher = hs.screen.watcher.new(function()
    scheduleApply(false)
end):start()

scheduleApply(false)
