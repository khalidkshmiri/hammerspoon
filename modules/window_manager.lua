package.loaded["modules.window_manager"] = nil

-- ── Window dragger / resizer + maximize toggle ────────────────────────────────
if _G.windowDragger then _G.windowDragger:stop() end
if _G.hyperWatcher  then _G.hyperWatcher:stop()  end
if _G.windowFilter  then _G.windowFilter:unsubscribeAll() end


hs.window.animationDuration = 0
local ANIMATE_DURATION = 0.2  -- seconds for maximize / restore transitions (drag stays instant)
local axuielement = require("hs.axuielement")

local types   = hs.eventtap.event.types
local props   = hs.eventtap.event.properties
local EV_DOWN  = types.leftMouseDown
local EV_DRAG  = types.leftMouseDragged
local EV_UP    = types.leftMouseUp
local EV_RDOWN  = types.rightMouseDown
local EV_RDRAG  = types.rightMouseDragged
local EV_RUP    = types.rightMouseUp
local EV_SCROLL = types.scrollWheel
local max, min = math.max, math.min

local SCROLL_RESIZE_SPEED   = 1.0  -- px of resize per px of scroll delta; negate to flip direction
local RESIZE_MARGIN         = 20   -- px from window edge: Hyper+drag here resizes
local DOUBLE_CLICK_INTERVAL = 0.22 -- seconds between two clicks to count as double-click
local TITLE_BAR_HEIGHT      = 32   -- px from window top: plain-drag intercept zone
local WINDOW_CONTROLS_WIDTH = 80   -- px from left: skip close/min/zoom buttons
local MIN_WIN_W             = 200
local MIN_WIN_H             = 100

local dragState   = {}
local dragGen     = 0
local lastClick   = { time = 0, winId = nil }
local pendingPlainDrag = nil
-- Scroll gesture target: locked when a scroll starts, released 0.3s after last event.
-- The event tap only accumulates deltas; a 60fps timer flushes them to setFrame so
-- the tap never blocks on slow-to-resize apps (Xcode, Reminders).
local scrollTarget = { window = nil, releaseTimer = nil, updateTimer = nil, edges = nil, initFrame = nil, totalDX = 0, totalDY = 0, dirty = false }
-- Hyper state tracked via flagsChanged so click events don't race with Karabiner-Elements
-- synthetic modifier delivery. The click event's own flags can arrive before all four
-- modifier keys are reflected, causing isHyper to return false and the click to fall
-- through to macOS native handling — which fires "Option hides other apps."
local hyperActive = false
_G.hyperWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(ev)
    local f = ev:getFlags()
    hyperActive = (f.cmd and f.ctrl and f.alt and f.shift) == true
end)
_G.hyperWatcher:start()

-- savedFrames[winId] = { pre = frame_before_maximize, max = frame_we_set_at_maximize }
-- Cleared when the user drags, resizes, or Hyper+double-clicks to restore.
local savedFrames = {}
local function isDesktopWindow(win)
    -- Lua treats 0 as truthy, so `not win:id()` does not identify this object.
    return win and win:role() == "AXScrollArea" and win:id() == 0
end

-- Golden Gate's desktop reveal can temporarily remove every app window from the
-- visible-window list. Keep the last real target so a Hyper gesture from Finder's
-- desktop still has a window to operate on.
local initialFrontmostWindow = hs.window.frontmostWindow()
local lastFocusedWindow = not isDesktopWindow(initialFrontmostWindow) and initialFrontmostWindow or nil

-- Clean up savedFrames when a window is closed so the table doesn't grow indefinitely.
_G.windowFilter = hs.window.filter.new()
_G.windowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
    local id = win:id()
    if id and savedFrames[id] then savedFrames[id] = nil end
    if lastFocusedWindow == win then lastFocusedWindow = nil end
end)
_G.windowFilter:subscribe(hs.window.filter.windowFocused, function(win)
    -- Finder's desktop is an AXScrollArea, not a target window.
    if not isDesktopWindow(win) then lastFocusedWindow = win end
end)

-- Fallback to the event's own flags: hyperActive (set only by flagsChanged) can go
-- stale when Karabiner delivers the Hyper modifiers without firing a flagsChanged
-- event, so scroll/right-drag resize would bail while the modifiers are actually held.
local function isHyper(event)
    if hyperActive then return true end
    if event then
        local f = event:getFlags()
        return (f.cmd and f.ctrl and f.alt and f.shift) == true
    end
    return false
end

-- buffer > 0 when Hyper is held so clicks in the native resize handle zone
-- (a few px outside the logical frame) still find the window.
local function getWindowAtPoint(pos, buffer)
    buffer = buffer or 0
    local focused = hs.window.focusedWindow()
    -- When the desktop is focused, hs.window.focusedWindow() returns Finder's
    -- full-screen AXScrollArea. It contains every point, so accepting it here
    -- prevents the ordered-window fallback from reaching the real window below.
    local focusedIsDesktop = isDesktopWindow(focused)
    if focused and not focusedIsDesktop then
        local f = focused:frame()
        if pos.x >= f.x - buffer and pos.x <= f.x + f.w + buffer and
           pos.y >= f.y - buffer and pos.y <= f.y + f.h + buffer then
            return focused, false
        end
    end
    for _, win in ipairs(hs.window.orderedWindows()) do
        if win ~= focused then
            local ok, f = pcall(function() return win:frame() end)
            if ok and f and pos.x >= f.x - buffer and pos.x <= f.x + f.w + buffer and
                            pos.y >= f.y - buffer and pos.y <= f.y + f.h + buffer then
                -- The displaced window can remain in orderedWindows briefly even
                -- though Finder's desktop still owns focus and AX writes are blocked.
                return win, focusedIsDesktop
            end
        end
    end
    -- With Finder's desktop focused, Golden Gate can move all app windows out of
    -- the visible list. Fall back to the last actual window rather than losing
    -- the gesture entirely; an invalid/closed cached window is handled by the
    -- existing protected setTopLeft/setFrame calls.
    if focusedIsDesktop and lastFocusedWindow then return lastFocusedWindow, true end
end

local function inResizeZone(pos, f)
    -- Guard against degenerate frames (e.g. w/h near 0) reported by AX right after a
    -- space switch, before which the "right/bottom edge" math would be true everywhere.
    if f.w <= 2 * RESIZE_MARGIN or f.h <= 2 * RESIZE_MARGIN then return false end
    return pos.x <= f.x + RESIZE_MARGIN or pos.x >= f.x + f.w - RESIZE_MARGIN or
           pos.y <= f.y + RESIZE_MARGIN or pos.y >= f.y + f.h - RESIZE_MARGIN
end

-- Maps cursor position to the nearest corner of the window using quadrants.
-- Used for Hyper+right-drag: resize from anywhere, not just the edge zone.
local function quadrantEdges(pos, f)
    local cx = f.x + f.w / 2
    local cy = f.y + f.h / 2
    return {
        left   = pos.x < cx,
        right  = pos.x >= cx,
        top    = pos.y < cy,
        bottom = pos.y >= cy,
    }
end

local function screenForPoint(pos)
    for _, screen in ipairs(hs.screen.allScreens()) do
        local sf = screen:frame()
        if pos.x >= sf.x and pos.x <= sf.x + sf.w and
           pos.y >= sf.y and pos.y <= sf.y + sf.h then
            return screen
        end
    end
    return hs.screen.primaryScreen()
end

local function boundsOnScreen(screen, w, h)
    local sf = screen:frame()
    -- Keep move drags fully in the usable screen frame. If a window is larger
    -- than the screen, pin its origin to the top-left rather than inverting bounds.
    return sf.x, max(sf.x, sf.x + sf.w - w), sf.y, max(sf.y, sf.y + sf.h - h)
end

local function screenRect(screen)
    local sf = screen:frame()
    return {
        left = sf.x,
        right = sf.x + sf.w,
        top = sf.y,
        bottom = sf.y + sf.h,
    }
end

local function resizeBounds(originScreen, pointerScreen)
    local origin = screenRect(originScreen)
    local bounds = {
        left = origin.left,
        right = origin.right,
        top = origin.top,
        bottom = origin.bottom,
    }

    if pointerScreen and pointerScreen ~= originScreen then
        local target = screenRect(pointerScreen)
        if target.left < origin.left then bounds.left = target.left end
        if target.right > origin.right then bounds.right = target.right end
        if target.top < origin.top then bounds.top = target.top end
        if target.bottom > origin.bottom then bounds.bottom = target.bottom end
    end

    return bounds
end

-- Returns true if the window's current frame is still at the position we maximized it to.
local function withAnimation(fn)
    hs.window.animationDuration = ANIMATE_DURATION
    fn()
    hs.window.animationDuration = 0
end

local function isStillMaximized(winId, currentF)
    if not savedFrames[winId] then return false end
    local m = savedFrames[winId].max
    return math.abs(currentF.x - m.x) < 5 and math.abs(currentF.y - m.y) < 5 and
           math.abs(currentF.w - m.w) < 5 and math.abs(currentF.h - m.h) < 5
end

local function inPlainTitleZone(pos, f)
    return pos.y >= f.y
       and pos.y <= f.y + TITLE_BAR_HEIGHT
       and pos.x >  f.x + WINDOW_CONTROLS_WIDTH
       and pos.x <  f.x + f.w - RESIZE_MARGIN
end

local CONTROL_ROLES = {
    AXButton = true,
    AXCheckBox = true,
    AXComboBox = true,
    AXDisclosureTriangle = true,
    AXMenuButton = true,
    AXPopUpButton = true,
    AXRadioButton = true,
    AXSearchField = true,
    AXSlider = true,
    AXTextField = true,
}

local function pointHitsTitleBarControl(pos)
    local ok, el = pcall(axuielement.systemElementAtPosition, pos)
    if not ok or not el then return false end

    while el do
        local role = el:attributeValue("AXRole")
        if CONTROL_ROLES[role] then return true end
        if role == "AXTitleBar" or role == "AXWindow" then return false end

        local parent = el:attributeValue("AXParent")
        if not parent or parent == el then return false end
        el = parent
    end

    return false
end

local function doMaximize(win, winId, currentF)
    local maxF = win:screen():frame()
    savedFrames[winId] = { pre = currentF, max = maxF }
    withAnimation(function() win:maximize() end)
    win:focus()
end

local function fallbackResizeEdges(initF, edges, dx, dy, bounds)
    local effective = {
        left = edges.left, right = edges.right,
        top = edges.top, bottom = edges.bottom,
    }

    -- When the selected edge is already against a screen limit, continue an
    -- outward resize from the opposite edge. This keeps a corner gesture useful
    -- at display boundaries instead of making it appear to stop responding.
    if edges.left and dx < 0 and initF.x <= bounds.left + 1 then
        effective.left, effective.right, dx = false, true, -dx
    elseif edges.right and dx > 0 and initF.x + initF.w >= bounds.right - 1 then
        effective.left, effective.right, dx = true, false, -dx
    end
    if edges.top and dy < 0 and initF.y <= bounds.top + 1 then
        effective.top, effective.bottom, dy = false, true, -dy
    elseif edges.bottom and dy > 0 and initF.y + initF.h >= bounds.bottom - 1 then
        effective.top, effective.bottom, dy = true, false, -dy
    end

    return effective, dx, dy
end

local function resizedFrame(initF, edges, dx, dy, originScreen, pointerScreen)
    local bounds = originScreen and resizeBounds(originScreen, pointerScreen)
    if bounds then
        edges, dx, dy = fallbackResizeEdges(initF, edges, dx, dy, bounds)
    end

    local newX, newY, newW, newH = initF.x, initF.y, initF.w, initF.h
    if edges.left then
        newW = max(MIN_WIN_W, initF.w - dx)
        newX = initF.x + initF.w - newW
    elseif edges.right then
        newW = max(MIN_WIN_W, initF.w + dx)
    end
    if edges.top then
        newH = max(MIN_WIN_H, initF.h - dy)
        newY = initF.y + initF.h - newH
    elseif edges.bottom then
        newH = max(MIN_WIN_H, initF.h + dy)
    end

    if not originScreen then
        return { x = newX, y = newY, w = newW, h = newH }
    end

    local left = newX
    local right = newX + newW
    local top = newY
    local bottom = newY + newH

    if edges.left then
        left = max(bounds.left, left)
        left = min(left, right - MIN_WIN_W)
    elseif edges.right then
        right = min(bounds.right, right)
        right = max(right, left + MIN_WIN_W)
    end

    if edges.top then
        top = max(bounds.top, top)
        top = min(top, bottom - MIN_WIN_H)
    elseif edges.bottom then
        bottom = min(bounds.bottom, bottom)
        bottom = max(bottom, top + MIN_WIN_H)
    end

    return {
        x = left,
        y = top,
        w = right - left,
        h = bottom - top,
    }
end

local function flushResize(state)
    pcall(
        state.window.setFrame,
        state.window,
        resizedFrame(
            state.initFrame,
            state.edges,
            state.totalDX,
            state.totalDY,
            state.originScreen,
            state.pointerScreen
        )
    )
end

local function newResizeState(win, frame, edges, pos)
    local originScreen = win:screen()
    local state = {
        window = win,
        isResize = true,
        isCmdDrag = true,
        didDrag = false,
        edges = edges,
        initFrame = frame,
        originScreen = originScreen,
        pointerScreen = originScreen,
        initMouseX = pos.x,
        initMouseY = pos.y,
        totalDX = 0,
        totalDY = 0,
        dirty = false,
    }
    state.resizeTimer = hs.timer.doEvery(1/60, function()
        if not state.dirty then return end
        state.dirty = false
        flushResize(state)
    end)
    return state
end

local function stopResize(state)
    if not state.resizeTimer then return end
    if state.dirty then flushResize(state) end
    state.resizeTimer:stop()
    state.resizeTimer = nil
end

local function resetScrollTarget()
    if scrollTarget.releaseTimer then scrollTarget.releaseTimer:stop() end
    if scrollTarget.updateTimer then scrollTarget.updateTimer:stop() end
    scrollTarget = { window = nil, releaseTimer = nil, updateTimer = nil, edges = nil, initFrame = nil, totalDX = 0, totalDY = 0, dirty = false }
end

_G.windowDragger = hs.eventtap.new({ EV_DOWN, EV_DRAG, EV_UP, EV_RDOWN, EV_RDRAG, EV_RUP, EV_SCROLL }, function(event)
    local eventType = event:getType()

    -- ── Mouse down ───────────────────────────────────────────────────────────
    if eventType == EV_DOWN then
        dragState = {}
        pendingPlainDrag = nil
        local hasHyper = isHyper(event)
        local pos      = event:location()
        -- 2 = the second click of a native double-click. Used below to give plain
        -- title-bar double-clicks the same maximize/restore as Hyper+double-click.
        local clickState = event:getProperty(props.mouseEventClickState)

        -- Fast path: skip the expensive window lookup when nothing to intercept.
        -- A plain double-click is the one no-Hyper case worth the lookup even with
        -- no saved frames (it may be a fresh window to maximize).
        if not hasHyper and next(savedFrames) == nil and clickState ~= 2 then return end

        local win, resumesDesktop = getWindowAtPoint(pos, hasHyper and RESIZE_MARGIN or 0)

        if not (win and not win:isFullScreen()) then
            if hasHyper then return true end
            return
        end

        -- AX ignores frame writes while wallpaper reveal is active. Focusing the
        -- cached window dismisses that system state before the drag starts.
        if resumesDesktop then win:focus() end

        local f     = win:frame()
        local winId = win:id()

        -- ── Plain (no Hyper): intercept title-bar drags on windows we maximized ──
        if not hasHyper then
            -- Native double-click on the title bar → same maximize/restore as
            -- Hyper+double-click, replacing macOS' default zoom/minimize. Applies to
            -- any window, not just ones we previously maximized.
            local inTitleZone = inPlainTitleZone(pos, f)
            local hitsControl = inTitleZone and pointHitsTitleBarControl(pos)
            if clickState == 2 and inTitleZone and not hitsControl then
                lastClick = { time = 0, winId = nil }
                if isStillMaximized(winId, f) then
                    local pre = savedFrames[winId].pre
                    savedFrames[winId] = nil
                    withAnimation(function() win:setFrame(pre) end)
                else
                    doMaximize(win, winId, f)
                end
                return true
            end

            local inTitleBar = savedFrames[winId]
                           and isStillMaximized(winId, f)
                           and inTitleZone
                           and not hitsControl
            if not inTitleBar then return end

            local minX, maxX, minY, maxY = boundsOnScreen(win:screen(), f.w, f.h)
            -- Plain top-bar clicks must pass through: app toolbars and native buttons live
            -- in this strip. We only take over after the click becomes an actual drag.
            pendingPlainDrag = {
                window     = win,
                x = f.x,   y = f.y,
                w = f.w,   h = f.h,
                minX = minX, maxX = maxX,
                minY = minY, maxY = maxY,
                isResize   = false,
                isCmdDrag  = false,
                didDrag    = false,
                savedFrame = savedFrames[winId].pre,
            }
            return false
        end

        -- ── Hyper held: resize / double-click / drag ──────────────────────────

        if inResizeZone(pos, f) then
            savedFrames[winId] = nil
            dragState = newResizeState(
                win,
                { x = f.x, y = f.y, w = f.w, h = f.h },
                quadrantEdges(pos, f),
                pos
            )
            return true
        end

        local now = hs.timer.secondsSinceEpoch()

        -- Double-click: restore if window is still at the maximized position,
        -- otherwise maximize (even if we had a previous save for this window).
        if lastClick.winId == winId and (now - lastClick.time) < DOUBLE_CLICK_INTERVAL then
            lastClick = { time = 0, winId = nil }
            if isStillMaximized(winId, f) then
                local pre = savedFrames[winId].pre
                savedFrames[winId] = nil
                withAnimation(function() win:setFrame(pre) end)
            else
                doMaximize(win, winId, f)
            end
            return true
        end

        -- Single Hyper+click: arm a move drag
        dragGen = dragGen + 1
        local minX, maxX, minY, maxY = boundsOnScreen(win:screen(), f.w, f.h)

        dragState = {
            window     = win,
            x = f.x,   y = f.y,
            w = f.w,   h = f.h,
            minX = minX, maxX = maxX,
            minY = minY, maxY = maxY,
            isResize   = false,
            isCmdDrag  = true,
            didDrag    = false,
            savedFrame = savedFrames[winId] and savedFrames[winId].pre,
            resumesDesktop = resumesDesktop,
            anchorMouseX = pos.x,
            anchorMouseY = pos.y,
            anchorWindowX = f.x,
            anchorWindowY = f.y,
        }
        return true

    -- ── Mouse drag ───────────────────────────────────────────────────────────
    elseif eventType == EV_DRAG then
        if pendingPlainDrag and not dragState.window then
            dragState = pendingPlainDrag
            pendingPlainDrag = nil
        end
        if not dragState.window then return end
        dragState.didDrag = true

        local dx = event:getProperty(props.mouseEventDeltaX)
        local dy = event:getProperty(props.mouseEventDeltaY)

        -- ── Resize mode ──────────────────────────────────────────────────────
        -- Accumulate total mouse offset from the initial position; the 60fps
        -- timer reads these and calls setFrame, decoupling the tap from slow apps.
        if dragState.isResize then
            local curPos = event:location()
            dragState.totalDX = curPos.x - dragState.initMouseX
            dragState.totalDY = curPos.y - dragState.initMouseY
            dragState.pointerScreen = screenForPoint(curPos)
            dragState.dirty   = true
            return true
        end

        -- ── Move mode ────────────────────────────────────────────────────────

        -- On first movement of a window we maximized: restore it to pre-maximize size.
        -- Cursor keeps its relative position within the window.
        if dragState.savedFrame then
            local saved  = dragState.savedFrame
            dragState.savedFrame = nil
            savedFrames[dragState.window:id()] = nil

            local curPos = hs.mouse.absolutePosition()
            local relX   = (curPos.x - dragState.x) / dragState.w
            local relY   = (curPos.y - dragState.y) / dragState.h
            local rx     = curPos.x - relX * saved.w
            local ry     = curPos.y - relY * saved.h
            local rs     = screenForPoint(curPos)
            local rminX, rmaxX, rminY, rmaxY = boundsOnScreen(rs, saved.w, saved.h)
            local cx     = max(rminX, min(rx, rmaxX))
            local cy     = max(rminY, min(ry, rmaxY))
            local frozenWin = dragState.window
            withAnimation(function()
                frozenWin:setFrame({ x = cx, y = cy, w = saved.w, h = saved.h })
            end)
            dragState.x, dragState.y = cx, cy
            dragState.w, dragState.h = saved.w, saved.h
            -- Freeze drag movement for the duration of the animation so live
            -- delta events don't fight the in-progress transition.
            dragState.animating = true
            dragGen = dragGen + 1
            local myGen = dragGen
            hs.timer.doAfter(ANIMATE_DURATION, function()
                if dragGen == myGen then
                    dragState.animating = false
                    -- Re-anchor position to actual window frame so first post-animation
                    -- delta applies from the right baseline.
                    local f = frozenWin:frame()
                    dragState.x, dragState.y = f.x, f.y
                end
            end)
        end

        if dragState.animating then return true end

        local screen = screenForPoint(hs.mouse.absolutePosition())
        dragState.minX, dragState.maxX, dragState.minY, dragState.maxY =
            boundsOnScreen(screen, dragState.w, dragState.h)

        local newX, newY
        if dragState.resumesDesktop then
            local curPos = event:location()
            newX = dragState.anchorWindowX + curPos.x - dragState.anchorMouseX
            newY = dragState.anchorWindowY + curPos.y - dragState.anchorMouseY
        else
            newX = dragState.x + dx
            newY = dragState.y + dy
        end
        newX = max(dragState.minX, min(newX, dragState.maxX))
        newY = max(dragState.minY, min(newY, dragState.maxY))

        local ok = pcall(dragState.window.setTopLeft, dragState.window, { x = newX, y = newY })
        if ok then
            dragState.x = newX
            dragState.y = newY
        else
            dragState = {}
        end
        return true

    -- ── Mouse up ─────────────────────────────────────────────────────────────
    elseif eventType == EV_UP then
        if pendingPlainDrag then
            pendingPlainDrag = nil
            return false
        end
        if dragState.window then
            stopResize(dragState)
            if dragState.isCmdDrag then
                if not dragState.didDrag then
                    lastClick = { time = hs.timer.secondsSinceEpoch(), winId = dragState.window:id() }
                else
                    lastClick = { time = 0, winId = nil }
                end
            end
            dragState = {}
            return true
        end

    -- ── Right mouse down: Hyper+right-drag = resize from nearest corner ───────
    -- Divides the window into four quadrants; the quadrant the cursor is in
    -- determines which corner gets dragged. Works from anywhere in the window.
    -- Uses the same 60fps timer approach as Hyper+left-drag edge resize.
    elseif eventType == EV_RDOWN then
        dragState = {}
        if not isHyper(event) then return end
        local pos = event:location()
        local win, resumesDesktop = getWindowAtPoint(pos, RESIZE_MARGIN)
        if not (win and not win:isFullScreen()) then return true end
        if resumesDesktop then win:focus() end

        local f     = win:frame()
        local winId = win:id()
        savedFrames[winId] = nil

        dragState = newResizeState(
            win,
            { x = f.x, y = f.y, w = f.w, h = f.h },
            quadrantEdges(pos, f),
            pos
        )
        return true

    -- ── Right mouse drag: accumulate delta for 60fps timer ───────────────────
    elseif eventType == EV_RDRAG then
        if not dragState.window or not dragState.isResize then return end
        dragState.didDrag = true
        local curPos      = event:location()
        dragState.totalDX = curPos.x - dragState.initMouseX
        dragState.totalDY = curPos.y - dragState.initMouseY
        dragState.pointerScreen = screenForPoint(curPos)
        dragState.dirty   = true
        return true

    -- ── Right mouse up: flush final frame and stop timer ─────────────────────
    elseif eventType == EV_RUP then
        if dragState.window then
            stopResize(dragState)
            dragState = {}
            return true
        end

    -- ── Scroll: Hyper + two-finger scroll = resize from nearest corner ────────
    -- Each scroll event applies directly to the current frame (no canvas needed).
    -- Quadrant under the cursor determines which corner is being resized.
    elseif eventType == EV_SCROLL then
        if not isHyper(event) then return end
        local pos = event:location()
        -- Reuse the locked target if mid-gesture; otherwise find by position.
        -- The lock prevents losing the window when it shrinks past the cursor.
        local win, resumesDesktop
        if scrollTarget.window then
            win = scrollTarget.window
        else
            win, resumesDesktop = getWindowAtPoint(pos, RESIZE_MARGIN)
        end
        if not (win and not win:isFullScreen()) then return true end
        if resumesDesktop then win:focus() end

        local dx = event:getProperty(props.scrollWheelEventPointDeltaAxis2)
        local dy = event:getProperty(props.scrollWheelEventPointDeltaAxis1)
        if dx == 0 and dy == 0 then return true end

        -- On the first real scroll event: snapshot frame and lock edges.
        -- Edges are locked so the resize direction can't flip as the window grows/shrinks.
        if not scrollTarget.window then
            local f = win:frame()
            local originScreen = win:screen()
            scrollTarget.window = win
            scrollTarget.edges = quadrantEdges(pos, f)
            scrollTarget.initFrame = { x = f.x, y = f.y, w = f.w, h = f.h }
            scrollTarget.originScreen = originScreen
            scrollTarget.pointerScreen = originScreen
            scrollTarget.totalDX = 0
            scrollTarget.totalDY = 0
            scrollTarget.dirty = false
            -- 60fps timer flushes accumulated deltas to setFrame independently of the
            -- event tap. This decouples the tap from slow app redraws (Xcode, Reminders)
            -- so the event queue never backs up — same principle as setTopLeft for move.
            scrollTarget.updateTimer = hs.timer.doEvery(1/60, function()
                if not scrollTarget.dirty then return end
                scrollTarget.dirty = false
                flushResize(scrollTarget)
            end)
        end

        -- Accumulate total scroll delta from the initial frame — the timer reads this.
        scrollTarget.totalDX = scrollTarget.totalDX + dx * SCROLL_RESIZE_SPEED
        scrollTarget.totalDY = scrollTarget.totalDY + dy * SCROLL_RESIZE_SPEED
        scrollTarget.pointerScreen = screenForPoint(pos)
        scrollTarget.dirty   = true

        -- Reset the release timer; on expiry stop the update timer and clean up.
        if scrollTarget.releaseTimer then scrollTarget.releaseTimer:stop() end
        scrollTarget.releaseTimer = hs.timer.doAfter(0.3, function()
            resetScrollTarget()
        end)
        return true
    end
end)

_G.windowDragger:start()
