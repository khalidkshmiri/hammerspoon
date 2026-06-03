package.loaded["modules.window_manager"] = nil

-- ── Window dragger / resizer + maximize toggle ────────────────────────────────
if _G.windowDragger then _G.windowDragger:stop() end
if _G.windowFilter then _G.windowFilter:unsubscribeAll() end

-- Clean up any canvas left over from a previous load (e.g. config saved mid-resize).
-- dragState is local so its canvas would otherwise be orphaned and stuck on screen.
if _G.activeResizeCanvas then
    pcall(function() _G.activeResizeCanvas:delete() end)
    _G.activeResizeCanvas = nil
end

hs.window.animationDuration = 0
local ANIMATE_DURATION = 0.2  -- seconds for maximize / restore transitions (drag stays instant)

local types   = hs.eventtap.event.types
local props   = hs.eventtap.event.properties
local EV_DOWN = types.leftMouseDown
local EV_DRAG = types.leftMouseDragged
local EV_UP   = types.leftMouseUp
local max, min = math.max, math.min

local RESIZE_MARGIN         = 20   -- px from window edge: Hyper+drag here resizes
local DOUBLE_CLICK_INTERVAL = 0.35 -- seconds between two Hyper+clicks to count as double-click
local TITLE_BAR_HEIGHT      = 32   -- px from window top: plain-drag intercept zone
local WINDOW_CONTROLS_WIDTH = 80   -- px from left: skip close/min/zoom buttons
local MIN_WIN_W             = 200
local MIN_WIN_H             = 100
local MIN_VISIBLE_X         = 100  -- min px of window width that must remain on-screen horizontally
local MIN_VISIBLE_Y         = 30   -- min px of window height that must remain on-screen vertically

-- Modifiers that must be held to activate window management.
-- Default is the Hyper key (all four). To use a lighter combo, remove entries:
--   Cmd + Ctrl only:       { cmd = true, ctrl = true }
--   Cmd + Ctrl + Opt:      { cmd = true, ctrl = true, alt = true }
local MODIFIER = { cmd = true, ctrl = true, alt = true, shift = true }

local dragState = {}
local dragGen   = 0
local lastClick = { time = 0, winId = nil }

-- savedFrames[winId] = { pre = frame_before_maximize, max = frame_we_set_at_maximize }
-- Cleared when the user drags, resizes, or Hyper+double-clicks to restore.
local savedFrames = {}

-- Clean up savedFrames when a window is closed so the table doesn't grow indefinitely.
_G.windowFilter = hs.window.filter.new()
_G.windowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
    local id = win:id()
    if id and savedFrames[id] then savedFrames[id] = nil end
end)

-- Returns true when all four Hyper modifiers are held.
-- Falls back to a live keyboard poll to handle the timing gap that Hyper-key remappers
-- (e.g. Karabiner-Elements) can introduce: the click event sometimes arrives before
-- all four modifier flags are reflected in the event itself.
local function isHyper(flags)
    local function checkMods(m)
        for mod in pairs(MODIFIER) do
            if not m[mod] then return false end
        end
        return true
    end
    if checkMods(flags) then return true end
    return checkMods(hs.eventtap.checkKeyboardModifiers())
end

-- buffer > 0 when Hyper is held so clicks in the native resize handle zone
-- (a few px outside the logical frame) still find the window.
local function getWindowAtPoint(pos, buffer)
    buffer = buffer or 0
    local focused = hs.window.focusedWindow()
    if focused then
        local f = focused:frame()
        if pos.x >= f.x - buffer and pos.x <= f.x + f.w + buffer and
           pos.y >= f.y - buffer and pos.y <= f.y + f.h + buffer then
            return focused
        end
    end
    for _, win in ipairs(hs.window.orderedWindows()) do
        if win ~= focused then
            local ok, f = pcall(function() return win:frame() end)
            if ok and f and pos.x >= f.x - buffer and pos.x <= f.x + f.w + buffer and
                            pos.y >= f.y - buffer and pos.y <= f.y + f.h + buffer then
                return win
            end
        end
    end
end

local function inResizeZone(pos, f)
    return pos.x <= f.x + RESIZE_MARGIN or pos.x >= f.x + f.w - RESIZE_MARGIN or
           pos.y <= f.y + RESIZE_MARGIN or pos.y >= f.y + f.h - RESIZE_MARGIN
end

local function resizeEdges(pos, f)
    return {
        left   = pos.x <= f.x + RESIZE_MARGIN,
        right  = pos.x >= f.x + f.w - RESIZE_MARGIN,
        top    = pos.y <= f.y + RESIZE_MARGIN,
        bottom = pos.y >= f.y + f.h - RESIZE_MARGIN,
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
    return sf.x - w + MIN_VISIBLE_X, sf.x + sf.w - MIN_VISIBLE_X, sf.y, sf.y + sf.h - MIN_VISIBLE_Y
end

-- Semi-transparent overlay that tracks the mouse during resize.
-- The actual window AX call happens once on mouse-up, keeping drag smooth.
-- Also registers the canvas globally so reload can clean it up if needed.
local function makeResizeCanvas(frame)
    local c = hs.canvas.new(frame)
    c:insertElement({
        action    = "fill",
        type      = "rectangle",
        fillColor = { red = 0.2, green = 0.2, blue = 0.2, alpha = 0.35 },
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
    })
    c:insertElement({
        action      = "stroke",
        type        = "rectangle",
        strokeColor = { white = 1, alpha = 0.5 },
        strokeWidth = 2,
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
    })
    c:show()
    _G.activeResizeCanvas = c
    return c
end

local function deleteResizeCanvas(c)
    pcall(function() c:delete() end)
    _G.activeResizeCanvas = nil
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

local function doMaximize(win, winId, currentF)
    local maxF = win:screen():frame()
    savedFrames[winId] = { pre = currentF, max = maxF }
    withAnimation(function() win:maximize() end)
    win:focus()
end

_G.windowDragger = hs.eventtap.new({ EV_DOWN, EV_DRAG, EV_UP }, function(event)
    local eventType = event:getType()

    -- ── Mouse down ───────────────────────────────────────────────────────────
    if eventType == EV_DOWN then
        dragState = {}
        local flags    = event:getFlags()
        local hasHyper = isHyper(flags)
        local pos      = event:location()

        -- Fast path: skip the expensive window lookup when nothing to intercept
        if not hasHyper and next(savedFrames) == nil then return end

        local win = getWindowAtPoint(pos, hasHyper and RESIZE_MARGIN or 0)

        if not (win and not win:isFullScreen()) then
            if hasHyper then return true end
            return
        end

        local f     = win:frame()
        local winId = win:id()

        -- ── Plain (no Hyper): intercept title-bar drags on windows we maximized ──
        if not hasHyper then
            local inTitleBar = savedFrames[winId]
                           and isStillMaximized(winId, f)
                           and pos.y >= f.y
                           and pos.y <= f.y + TITLE_BAR_HEIGHT
                           and pos.x >  f.x + WINDOW_CONTROLS_WIDTH
                           and pos.x <  f.x + f.w - RESIZE_MARGIN
            if not inTitleBar then return end

            local minX, maxX, minY, maxY = boundsOnScreen(win:screen(), f.w, f.h)
            dragState = {
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
            win:focus()
            return true
        end

        -- ── Hyper held: resize / double-click / drag ──────────────────────────

        if inResizeZone(pos, f) then
            savedFrames[winId] = nil
            local initF = { x = f.x, y = f.y, w = f.w, h = f.h }
            dragState = {
                window       = win,
                isResize     = true,
                edges        = resizeEdges(pos, f),
                isCmdDrag    = true,
                didDrag      = false,
                initMouseX   = pos.x,
                initMouseY   = pos.y,
                initFrame    = initF,
                canvasFrame  = initF,
                resizeCanvas = makeResizeCanvas(initF),
            }
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
        }
        return true

    -- ── Mouse drag ───────────────────────────────────────────────────────────
    elseif eventType == EV_DRAG then
        if not dragState.window then return end
        dragState.didDrag = true

        local dx = event:getProperty(props.mouseEventDeltaX)
        local dy = event:getProperty(props.mouseEventDeltaY)

        -- ── Resize mode ──────────────────────────────────────────────────────
        -- Only move the canvas overlay — no AX calls on the actual window.
        -- The window is resized once on mouse-up to keep drag perfectly smooth.
        if dragState.isResize then
            local curPos  = event:location()
            local totalDX = curPos.x - dragState.initMouseX
            local totalDY = curPos.y - dragState.initMouseY
            local e       = dragState.edges
            local initF   = dragState.initFrame

            local newX = initF.x
            local newY = initF.y
            local newW = initF.w
            local newH = initF.h

            if e.left then
                newW = max(MIN_WIN_W, initF.w - totalDX)
                newX = initF.x + initF.w - newW  -- anchor right edge
            elseif e.right then
                newW = max(MIN_WIN_W, initF.w + totalDX)
            end

            if e.top then
                newH = max(MIN_WIN_H, initF.h - totalDY)
                newY = initF.y + initF.h - newH  -- anchor bottom edge
            elseif e.bottom then
                newH = max(MIN_WIN_H, initF.h + totalDY)
            end

            local cf = { x = newX, y = newY, w = newW, h = newH }
            dragState.resizeCanvas:frame(cf)
            dragState.canvasFrame = cf
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

        local newX = max(dragState.minX, min(dragState.x + dx, dragState.maxX))
        local newY = max(dragState.minY, min(dragState.y + dy, dragState.maxY))

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
        if dragState.window then
            if dragState.resizeCanvas then
                -- Commit the canvas frame to the actual window in one atomic AX call.
                -- Using setFrame (vs separate setTopLeft + setSize) avoids a race where
                -- some apps snap back between the two calls.
                if dragState.didDrag then
                    pcall(dragState.window.setFrame, dragState.window, dragState.canvasFrame)
                end
                deleteResizeCanvas(dragState.resizeCanvas)
            end
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
    end
end)

_G.windowDragger:start()
