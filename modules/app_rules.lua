package.loaded["modules.app_rules"] = nil

-- ── App layout: capture & restore ─────────────────────────────────────────────
-- A fixed set of apps lives together in one persistent desktop Space (Music,
-- Reminders, Mail, Calendar, Messages). You arrange them once exactly how you like,
-- press Hyper+S to capture that arrangement as the standard, and press Hyper+R any
-- time things drift to snap them back.
--
-- Deliberately NOT automatic: a launch/activate watcher would fight you every time
-- you temporarily drag an app to another Space or resize a window. Restore is
-- manual, so nothing is ever moved unless you ask for it.
--
-- The captured layout is persisted via hs.settings, so it survives config reloads
-- and restarts — capture once, keep it forever.
--
-- Spaces caveat: macOS gives Hammerspoon no reliable way to MOVE a window between
-- Spaces. Restore only sets each window's frame (position + size) on whatever Space
-- it currently sits on. If you've parked an app on another Space, restore will
-- reposition it there; drag it back to its home Space yourself.

local HYPER       = { "cmd", "ctrl", "alt", "shift" }
local SETTINGS_KEY = "appRules.layout"

-- bundleID → friendly name. Order is only used for the capture/restore summary.
local APPS = {
    { id = "com.apple.Music",     name = "Music"     },
    { id = "com.apple.reminders", name = "Reminders" },
    { id = "com.apple.mail",      name = "Mail"      },
    { id = "com.apple.iCal",      name = "Calendar"  },
    { id = "com.apple.MobileSMS", name = "Messages"  },
}

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

-- ── Restore: snap each app back to its captured frame ──────────────────────────
local function restoreLayout()
    local layout = hs.settings.get(SETTINGS_KEY)
    if not layout or next(layout) == nil then
        hs.alert.show("No layout captured yet — arrange apps, then Hyper+S")
        return
    end
    local restored = {}
    for _, entry in ipairs(APPS) do
        local f = layout[entry.id]
        local app = f and hs.application.get(entry.id)
        local win = app and primaryWindow(app)
        if win then
            win:setFrame(hs.geometry.rect(f.x, f.y, f.w, f.h))
            restored[#restored + 1] = entry.name
        end
    end
    if #restored == 0 then
        hs.alert.show("Layout: none of the apps are running")
    else
        hs.alert.show("Layout restored:\n" .. table.concat(restored, ", "))
    end
end

if _G.appRulesCaptureHK then _G.appRulesCaptureHK:delete() end
if _G.appRulesRestoreHK then _G.appRulesRestoreHK:delete() end
_G.appRulesCaptureHK = hs.hotkey.bind(HYPER, "s", captureLayout)
_G.appRulesRestoreHK = hs.hotkey.bind(HYPER, "r", restoreLayout)

-- Exposed for the `hs` CLI / debugging.
_G.captureLayout = captureLayout
_G.restoreLayout = restoreLayout
