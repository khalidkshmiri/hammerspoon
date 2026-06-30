package.loaded["modules.click_quit"] = nil

-- ── Quit a Dock or menu-bar app: middle-click, or Hyper+click ────────────────
if _G.clickQuitTap then _G.clickQuitTap:stop() end

local ax       = hs.axuielement
local eventtap = hs.eventtap
local types    = eventtap.event.types

local PROTECTED = {
    ["com.apple.finder"]            = true,
    ["com.apple.dock"]              = true,
    ["com.apple.controlcenter"]     = true,
    ["com.apple.systemuiserver"]    = true,
    ["com.apple.Spotlight"]         = true,
    ["org.hammerspoon.Hammerspoon"] = true,
}

local function isQuitTrigger(e)
    if e:getType() == types.otherMouseDown then
        return e:getButtonState(2)
    end
    local f = e:getFlags()
    return f.cmd and f.ctrl and f.alt and f.shift
end

local function appIsProtected(app)
    local bundleID = app and app:bundleID()
    return bundleID and PROTECTED[bundleID]
end

local function dockItemAt(point)
    local dockApp = hs.application.find("com.apple.dock")
    if not dockApp then return nil end

    local dockEl = ax.applicationElement(dockApp)
    local list = dockEl and dockEl[1]
    if not list then return nil end

    local p = hs.geometry.point(point)
    for _, item in ipairs(list) do
        local pos, size = item.AXPosition, item.AXSize
        if pos and size and p:inside(hs.geometry.rect(pos.x, pos.y, size.w, size.h)) then
            return item
        end
    end
end

local function dockAppForItem(item)
    local url = item.AXURL
    if type(url) == "table" and url.filePath then
        local info = hs.application.infoForBundlePath(url.filePath)
        if info and info.CFBundleIdentifier then
            local app = hs.application.get(info.CFBundleIdentifier)
            if app then return app end
        end
    end
    if item.AXTitle then return hs.application.find(item.AXTitle) end
end

local function quitDockAppAt(point)
    local item = dockItemAt(point)
    if not item then return false end
    if item.AXSubrole ~= "AXApplicationDockItem" or not item.AXIsApplicationRunning then return false end

    local app = dockAppForItem(item)
    if not app or appIsProtected(app) then return false end
    app:kill()
    return true
end

local function menubarBottom(point)
    for _, screen in ipairs(hs.screen.allScreens()) do
        local ff = screen:fullFrame()
        if point.x >= ff.x and point.x <= ff.x + ff.w and
           point.y >= ff.y and point.y <= ff.y + ff.h then
            return ff.y + (screen:frame().y - ff.y)
        end
    end
end

local function quitMenubarAppAt(point)
    local bottom = menubarBottom(point)
    if not bottom or point.y > bottom then return false end

    local el = ax.systemWideElement():elementAtPosition(point.x, point.y)
    if not el then return false end

    local ok, pid = pcall(function() return el:pid() end)
    if not ok or not pid then return false end

    local app = hs.application.applicationForPID(pid)
    if not app or appIsProtected(app) then return false end
    app:kill()
    return true
end

-- NOTE: window_manager also taps leftMouseDown for Hyper+drag; load this after it
-- so quit-clicks over the Dock/menu bar are swallowed before window_manager sees them.
_G.clickQuitTap = eventtap.new({ types.otherMouseDown, types.leftMouseDown }, function(e)
    if not isQuitTrigger(e) then return false end
    local point = hs.mouse.absolutePosition()
    return quitDockAppAt(point) or quitMenubarAppAt(point)
end)

_G.clickQuitTap:start()
