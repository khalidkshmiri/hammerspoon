package.loaded["modules.app_rules"] = nil

-- ── App-launch rules ──────────────────────────────────────────────────────────
-- When an app launches (or is activated), apply a layout rule: pin it to a screen,
-- a position, and/or a size — so e.g. the browser always opens left, the terminal
-- always opens right, with no manual dragging.
--
-- SCAFFOLD: RULES is intentionally empty. Tell Claude which apps and how you like
-- them and they'll be filled in. Format of each rule (all fields optional except a
-- key, which is the app's bundle ID OR its name):
--
--   ["com.google.Chrome"] = { screen = "main", unit = { 0, 0, 0.5, 1 } },
--   ["Ghostty"]           = { screen = "main", unit = { 0.5, 0, 0.5, 1 } },
--   ["Spotify"]           = { screen = 2,      maximize = true },
--
--   screen   : "main" | "primary" | a 1-based index | a screen-name substring
--   unit     : { x, y, w, h } as fractions of the screen (0–1). 0,0,0.5,1 = left half
--   maximize : true to fill the screen (ignores unit)
--   frame    : { x, y, w, h } absolute px (overrides unit/maximize; rarely needed)

if _G.appRulesWatcher then _G.appRulesWatcher:stop() end

local RULES = {
    -- (empty — to be filled in once you pick apps + layouts)
}

local function ruleFor(app)
    return RULES[app:bundleID() or ""] or RULES[app:name() or ""]
end

local function resolveScreen(spec)
    if spec == nil or spec == "main" or spec == "primary" then
        return hs.screen.primaryScreen()
    end
    if type(spec) == "number" then
        return hs.screen.allScreens()[spec] or hs.screen.primaryScreen()
    end
    return hs.screen.find(spec) or hs.screen.primaryScreen()
end

-- Apply a rule to an app's main (or first) window.
local function apply(app, rule)
    local win = app:mainWindow() or (app:allWindows() or {})[1]
    if not win then return end
    local screen = resolveScreen(rule.screen)

    if rule.frame then
        win:setFrame(rule.frame)
    elseif rule.maximize then
        win:moveToScreen(screen); win:maximize()
    elseif rule.unit then
        win:moveToScreen(screen)
        win:moveToUnit(hs.geometry.rect(table.unpack(rule.unit)))
    elseif rule.screen ~= nil then
        win:moveToScreen(screen)
    end
end

_G.appRulesWatcher = hs.application.watcher.new(function(name, event, app)
    if event ~= hs.application.watcher.launched then return end
    local rule = ruleFor(app)
    if not rule then return end
    -- Windows often aren't laid out yet at launch; retry briefly until one appears
    -- (or give up after ~2s).
    local tries = 0
    local t
    t = hs.timer.doEvery(0.2, function()
        tries = tries + 1
        if app:mainWindow() then
            apply(app, rule); t:stop()
        elseif tries >= 10 then
            t:stop()
        end
    end)
end)
_G.appRulesWatcher:start()
