package.loaded["modules.menubar_quit"] = nil

-- ── Quit a menu-bar item: middle-click, or Hyper+click ────────────────────────
-- Two ways to quit the app owning a third-party menu-bar status item, gracefully
-- (≡ ⌘Q):
--   • Middle-click           — for a mouse with a middle button.
--   • Hyper+click (⌘⌃⌥⇧)     — trackpad parity, since a MacBook has no middle button.
-- Hyper is used because no system menu-bar gesture claims it (same reasoning as
-- dock_quit.lua). Apple's own system items (Control Center, clock, Spotlight, Wi-Fi…),
-- Finder, and clicks outside the menu-bar strip are left alone.

if _G.menubarQuitTap then _G.menubarQuitTap:stop() end

local eventtap = hs.eventtap
local types    = eventtap.event.types
local ax       = hs.axuielement

-- Bundle IDs we never quit: system UI owners + Finder/Dock/Hammerspoon. Killing
-- these is either pointless (they relaunch) or self-defeating.
local PROTECTED = {
    ["com.apple.controlcenter"]  = true,
    ["com.apple.systemuiserver"] = true,
    ["com.apple.Spotlight"]      = true,
    ["com.apple.finder"]         = true,
    ["com.apple.dock"]           = true,
    ["org.hammerspoon.Hammerspoon"] = true,
}

-- Height of the menu-bar strip on the screen under a point: the gap between the
-- usable frame and the full frame. ~24–37px depending on notch.
local function menubarBottom(point)
    for _, screen in ipairs(hs.screen.allScreens()) do
        local ff = screen:fullFrame()
        if point.x >= ff.x and point.x <= ff.x + ff.w and
           point.y >= ff.y and point.y <= ff.y + ff.h then
            return ff.y + (screen:frame().y - ff.y)
        end
    end
    return nil
end

-- NOTE: window_manager also taps leftMouseDown for Hyper+drag; menubar_quit is loaded
-- after it in init.lua, so this tap sits at the event-chain head and sees the click
-- first — swallowing it (return true) here keeps window_manager from also acting on a
-- Hyper+click over the menu bar. Don't reorder the loads in init.lua.
_G.menubarQuitTap = eventtap.new({ types.otherMouseDown, types.leftMouseDown }, function(e)
    if e:getType() == types.otherMouseDown then
        -- Button 2 is the middle button (0=left, 1=right).
        if not e:getButtonState(2) then return false end
    else
        -- leftMouseDown: only act on a Hyper+click. Read the event's own flags rather
        -- than a flagsChanged-tracked state — Karabiner can make that state stale
        -- relative to the click (see window_manager.lua).
        local f = e:getFlags()
        if not (f.cmd and f.ctrl and f.alt and f.shift) then return false end
    end

    local pos    = hs.mouse.absolutePosition()
    local bottom = menubarBottom(pos)
    -- Only act inside the menu-bar strip; everything below passes through.
    if not bottom or pos.y > bottom then return false end

    -- Resolve the AX element directly under the cursor and the app that owns it.
    local el = ax.systemWideElement():elementAtPosition(pos.x, pos.y)
    if not el then return false end
    local ok, pid = pcall(function() return el:pid() end)
    if not ok or not pid then return false end

    local app = hs.application.applicationForPID(pid)
    if not app then return false end

    local bundleID = app:bundleID()
    if bundleID and PROTECTED[bundleID] then return false end

    local name = app:name()
    app:kill() -- graceful terminate, equivalent to ⌘Q

    return true -- swallow only the clicks we actually handle
end)

_G.menubarQuitTap:start()
