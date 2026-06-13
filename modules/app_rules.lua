package.loaded["modules.app_rules"] = nil

-- ── App layout: auto-restore on launch ────────────────────────────────────────
-- A fixed set of apps lives together in one persistent desktop Space (Music,
-- Reminders, Mail, Calendar, Messages). You arrange them once, save that as the
-- standard, and from then on each app snaps back to its saved frame automatically
-- whenever it launches — nothing to press, nothing to think about.
--
-- Why launch-only (and never on activate/move): re-snapping continuously would fight
-- you every time you temporarily drag or resize a window. Acting only at open time is
-- the safe form of automation — a freshly launched window has no position you care
-- about yet, so moving it can't undo anything you intended.
--
-- No keybinds. Restore is fully automatic. To (re)capture the standard arrangement,
-- arrange the apps and run from a terminal:  hs -c "captureLayout()"
--
-- The captured layout is persisted via hs.settings, so it survives config reloads
-- and restarts — capture once, keep it forever.
--
-- Spaces caveat: macOS gives Hammerspoon no reliable way to MOVE a window between
-- Spaces. Restore only sets each window's frame (position + size) on whatever Space
-- it currently sits on. If you've parked an app on another Space, restore will
-- reposition it there; drag it back to its home Space yourself.

local SETTINGS_KEY = "appRules.layout"

-- bundleID → friendly name. Order is only used for the capture/restore summary.
local APPS = {
    { id = "com.apple.Music",     name = "Music"     },
    { id = "com.apple.reminders", name = "Reminders" },
    { id = "com.apple.mail",      name = "Mail"      },
    { id = "com.apple.iCal",      name = "Calendar"  },
    { id = "com.apple.MobileSMS", name = "Messages"  },
}

-- bundleID → entry, so the launch watcher can O(1)-check "is this one of mine?"
local APP_BY_ID = {}
for _, entry in ipairs(APPS) do APP_BY_ID[entry.id] = entry end

-- The window we treat as an app's "main" one — mainWindow if focused recently,
-- else the first standard (non-panel) window.
local function primaryWindow(app)
    local win = app:mainWindow()
    if win and win:isStandard() then return win end
    for _, w in ipairs(app:allWindows() or {}) do
        if w:isStandard() then return w end
    end
    return win
end

-- ── Capture: read each running app's current frame, save as the standard ───────
local function captureLayout()
    local layout = {}
    local saved = {}
    for _, entry in ipairs(APPS) do
        local app = hs.application.get(entry.id)
        local win = app and primaryWindow(app)
        if win then
            local f = win:frame()
            layout[entry.id] = { x = f.x, y = f.y, w = f.w, h = f.h }
            saved[#saved + 1] = entry.name
        end
    end
    hs.settings.set(SETTINGS_KEY, layout)
    if #saved == 0 then
        hs.alert.show("Layout: no windows found to capture")
    else
        hs.alert.show("Layout captured:\n" .. table.concat(saved, ", "))
    end
end

-- Snap one app's primary window back to its saved frame. Returns true if it did.
local function restoreApp(entry, layout)
    local f = layout and layout[entry.id]
    local app = f and hs.application.get(entry.id)
    local win = app and primaryWindow(app)
    if not win then return false end
    win:setFrame(hs.geometry.rect(f.x, f.y, f.w, f.h))
    return true
end

-- ── Restore: snap each app back to its captured frame (CLI / manual catch-all) ─
local function restoreLayout()
    local layout = hs.settings.get(SETTINGS_KEY)
    if not layout or next(layout) == nil then
        hs.alert.show('No layout captured yet — arrange apps, then run hs -c "captureLayout()"')
        return
    end
    local restored = {}
    for _, entry in ipairs(APPS) do
        if restoreApp(entry, layout) then restored[#restored + 1] = entry.name end
    end
    if #restored == 0 then
        hs.alert.show("Layout: none of the apps are running")
    else
        hs.alert.show("Layout restored:\n" .. table.concat(restored, ", "))
    end
end

-- ── Auto-restore on launch ─────────────────────────────────────────────────────
-- A just-launched app usually has no window yet, so poll briefly until its primary
-- window exists, then restore once. ~10 tries × 0.3s ≈ 3s budget before giving up.
local function restoreAppWhenReady(entry)
    local attempts = 0
    local function tryRestore()
        attempts = attempts + 1
        local layout = hs.settings.get(SETTINGS_KEY)
        if restoreApp(entry, layout) then return end       -- done
        if attempts < 10 then hs.timer.doAfter(0.3, tryRestore) end
    end
    tryRestore()
end

if _G.appRulesWatcher then _G.appRulesWatcher:stop() end
_G.appRulesWatcher = hs.application.watcher.new(function(_, event, app)
    -- Launch only: never on activate/deactivate, so moves are never re-snapped.
    if event ~= hs.application.watcher.launched then return end
    local entry = app and APP_BY_ID[app:bundleID()]
    if entry then restoreAppWhenReady(entry) end
end)
_G.appRulesWatcher:start()

-- Exposed for the `hs` CLI — the only way to (re)capture or force a restore now.
_G.captureLayout = captureLayout
_G.restoreLayout = restoreLayout
