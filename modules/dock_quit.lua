package.loaded["modules.dock_quit"] = nil

-- ── Quit a Dock app: middle-click, or Hyper+click ─────────────────────────────
-- Two ways to quit a running app's Dock icon gracefully (≡ ⌘Q):
--   • Middle-click           — for a mouse with a middle button.
--   • Hyper+click (⌘⌃⌥⇧)     — trackpad parity, since a MacBook has no middle button.
-- Hyper is used because no system Dock gesture claims it (unlike ⌘-click = reveal in
-- Finder, ⌃-click = menu, ⌥-click = hide others). Anything else (non-running icons,
-- protected apps, Trash/stacks, minimized windows, clicks outside the Dock) passes
-- through untouched.

if _G.dockQuitTap then _G.dockQuitTap:stop() end

local eventtap = hs.eventtap
local ax       = hs.axuielement
local types    = eventtap.event.types

-- Bundle IDs we never quit: killing these is pointless (they relaunch) or self-defeating.
local PROTECTED = {
    ["com.apple.finder"]            = true,
    ["com.apple.dock"]              = true,
    ["com.apple.controlcenter"]     = true,
    ["com.apple.systemuiserver"]    = true,
    ["com.apple.Spotlight"]         = true,
    ["org.hammerspoon.Hammerspoon"] = true,
}

-- Find the AXDockItem under the given screen point, or nil. We hit-test each dock
-- item's own frame rather than using elementAtPosition, which can return a child
-- glyph instead of the dock item itself.
local function dockItemAt(point)
    local dockApp = hs.application.find("com.apple.dock")
    if not dockApp then return nil end

    local dockEl = ax.applicationElement(dockApp)
    if not dockEl then return nil end

    -- The Dock's first child is the AXList holding all the dock items.
    local list = dockEl[1]
    if not list then return nil end

    local p = hs.geometry.point(point)
    for _, item in ipairs(list) do
        local pos, size = item.AXPosition, item.AXSize
        if pos and size then
            local frame = hs.geometry.rect(pos.x, pos.y, size.w, size.h)
            if p:inside(frame) then return item end
        end
    end
    return nil
end

-- Resolve the running hs.application for a dock item, preferring its bundle URL
-- (exact) over its title (a name match, used only as a fallback).
local function appForItem(item)
    -- AXURL is an NSURL-backed table with a ready-decoded .filePath to the .app bundle.
    local url = item.AXURL
    if type(url) == "table" and url.filePath then
        local info = hs.application.infoForBundlePath(url.filePath)
        if info and info.CFBundleIdentifier then
            local app = hs.application.get(info.CFBundleIdentifier)
            if app then return app end
        end
    end
    if item.AXTitle then return hs.application.find(item.AXTitle) end
    return nil
end

-- Quit the running app whose Dock icon is under `point`. Returns true only when it
-- actually killed something (so the caller knows whether to swallow the click).
local function quitAppAtDock(point)
    local item = dockItemAt(point)
    if not item then return false end

    -- Only application icons that are actually running. Excludes the separator,
    -- Trash, Downloads/stacks, minimized window thumbnails, and apps that aren't open.
    if item.AXSubrole ~= "AXApplicationDockItem" then return false end
    if not item.AXIsApplicationRunning then return false end

    local app = appForItem(item)
    if not app then return false end

    -- Skip Finder/Dock/system UI: killing them is pointless (they relaunch).
    local bundleID = app:bundleID()
    if bundleID and PROTECTED[bundleID] then return false end

    app:kill() -- graceful terminate, equivalent to ⌘Q

    return true
end

-- One tap for both triggers. NOTE: window_manager also taps leftMouseDown for Hyper+drag;
-- dock_quit is loaded *after* it in init.lua, so this tap sits at the event-chain head and
-- sees the click first — swallowing it (return true) here keeps window_manager from also
-- acting on a Hyper+click over the Dock. Don't reorder the loads in init.lua.
_G.dockQuitTap = eventtap.new({ types.otherMouseDown, types.leftMouseDown }, function(e)
    if e:getType() == types.otherMouseDown then
        -- Button 2 is the middle button (0=left, 1=right).
        if not e:getButtonState(2) then return false end
    else
        -- leftMouseDown: only act on a Hyper+click. Read the event's own flags rather
        -- than a flagsChanged-tracked state — Karabiner can make that state stale
        -- relative to the click (see window_manager.lua). The cheap flag check first
        -- means ordinary left-clicks fall straight through.
        local f = e:getFlags()
        if not (f.cmd and f.ctrl and f.alt and f.shift) then return false end
    end

    return quitAppAtDock(hs.mouse.absolutePosition()) -- swallow only the clicks we handle
end)

_G.dockQuitTap:start()
