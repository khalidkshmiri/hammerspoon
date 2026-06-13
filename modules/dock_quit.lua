package.loaded["modules.dock_quit"] = nil

-- ── Middle-click a Dock icon to quit the app ──────────────────────────────────
-- Middle-clicking a running app's Dock icon quits it gracefully (≡ ⌘Q).
-- Anything else (non-running icons, Finder/Trash/stacks, minimized windows, or
-- middle-clicks outside the Dock) passes through untouched.

if _G.dockQuitTap then _G.dockQuitTap:stop() end

local eventtap = hs.eventtap
local ax       = hs.axuielement
local types    = eventtap.event.types

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

_G.dockQuitTap = eventtap.new({ types.otherMouseDown }, function(e)
    -- Button 2 is the middle button (0=left, 1=right).
    if not e:getButtonState(2) then return false end

    local item = dockItemAt(hs.mouse.absolutePosition())
    if not item then return false end

    -- Only application icons that are actually running. Excludes the separator,
    -- Trash, Downloads/stacks, Finder, minimized window thumbnails, and apps that
    -- aren't open.
    if item.AXSubrole ~= "AXApplicationDockItem" then return false end
    if not item.AXIsApplicationRunning then return false end

    local app = appForItem(item)
    if not app then return false end

    app:kill() -- graceful terminate, equivalent to ⌘Q
    hs.alert.show("Quit " .. (item.AXTitle or app:name() or "app"))

    return true -- swallow only the clicks we actually handle
end)

_G.dockQuitTap:start()
