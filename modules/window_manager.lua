package.loaded["modules.window_manager"] = nil

-- ── Window dragger / resizer + maximize toggle ────────────────────────────────
if _G.windowDragger then _G.windowDragger:stop() end
if _G.hyperWatcher  then _G.hyperWatcher:stop()  end
if _G.windowFilter  then _G.windowFilter:unsubscribeAll() end

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
local EV_DOWN  = types.leftMouseDown
local EV_DRAG  = types.leftMouseDragged
local EV_UP    = types.leftMouseUp
local EV_RDOWN  = types.rightMouseDown
local EV_RDRAG  = types.rightMouseDragged
local EV_RUP    = types.rightMouseUp
local EV_SCROLL = types.scrollWheel
local max, min = math.max, math.min

local SCROLL_RESIZE_SPEED   = 2    -- px of resize per px of scroll delta; negate to flip direction
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

local dragState   = {}
local dragGen     = 0
local lastClick   = { time = 0, winId = nil }
-- Scroll gesture target: locked when a scroll starts, released 0.3s after last event.
-- The event tap only accumulates deltas; a 60fps timer flushes them to setFrame so
-- the tap never blocks on slow-to-resize apps (Xcode, Reminders).
local scrollTarget = { win = nil, releaseTimer = nil, updateTimer = nil, edges = nil, initFrame = nil, totalDX = 0, totalDY = 0, dirty = false }
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

-- Clean up savedFrames when a window is closed so the table doesn't grow indefinitely.
_G.windowFilter = hs.window.filter.new()
_G.windowFilter:subscribe(hs.window.filter.windowDestroyed, function(win)
    local id = win:id()
    if id and savedFrames[id] then savedFrames[id] = nil end
end)

local function isHyper() return hyperActive end

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

_G.windowDragger = hs.eventtap.new({ EV_DOWN, EV_DRAG, EV_UP, EV_RDOWN, EV_RDRAG, EV_RUP, EV_SCROLL }, function(event)
    local eventType = event:getType()

    -- ── Mouse down ───────────────────────────────────────────────────────────
    if eventType == EV_DOWN then
        dragState = {}
        local hasHyper = isHyper()
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
            return true
        end

        -- ── Hyper held: resize / double-click / drag ──────────────────────────

        if inResizeZone(pos, f) then
            savedFrames[winId] = nil
            local initF = { x = f.x, y = f.y, w = f.w, h = f.h }
            local ds = {
                window       = win,
                isResize     = true,
                edges        = resizeEdges(pos, f),
                isCmdDrag    = true,
                didDrag      = false,
                initMouseX   = pos.x,
                initMouseY   = pos.y,
                initFrame    = initF,
                totalDX      = 0,
                totalDY      = 0,
                dirty        = false,
            }
            -- 60fps timer flushes accumulated deltas to setFrame, same as scroll resize.
            -- Keeps drag smooth even when the target app is slow to respond to AX calls.
            ds.resizeTimer = hs.timer.doEvery(1/60, function()
                if not ds.dirty then return end
                ds.dirty = false
                local e     = ds.edges
                local initF = ds.initFrame
                local newX  = initF.x
                local newY  = initF.y
                local newW  = initF.w
                local newH  = initF.h
                if e.left then
                    newW = max(MIN_WIN_W, initF.w - ds.totalDX)
                    newX = initF.x + initF.w - newW
                elseif e.right then
                    newW = max(MIN_WIN_W, initF.w + ds.totalDX)
                end
                if e.top then
                    newH = max(MIN_WIN_H, initF.h - ds.totalDY)
                    newY = initF.y + initF.h - newH
                elseif e.bottom then
                    newH = max(MIN_WIN_H, initF.h + ds.totalDY)
                end
                pcall(ds.window.setFrame, ds.window, { x = newX, y = newY, w = newW, h = newH })
            end)
            dragState = ds
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
        -- Accumulate total mouse offset from the initial position; the 60fps
        -- timer reads these and calls setFrame, decoupling the tap from slow apps.
        if dragState.isResize then
            local curPos = event:location()
            dragState.totalDX = curPos.x - dragState.initMouseX
            dragState.totalDY = curPos.y - dragState.initMouseY
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
            if dragState.resizeTimer then
                -- Flush any last pending delta before stopping the timer.
                if dragState.dirty then
                    local e     = dragState.edges
                    local initF = dragState.initFrame
                    local newX  = initF.x
                    local newY  = initF.y
                    local newW  = initF.w
                    local newH  = initF.h
                    if e.left then
                        newW = max(MIN_WIN_W, initF.w - dragState.totalDX)
                        newX = initF.x + initF.w - newW
                    elseif e.right then
                        newW = max(MIN_WIN_W, initF.w + dragState.totalDX)
                    end
                    if e.top then
                        newH = max(MIN_WIN_H, initF.h - dragState.totalDY)
                        newY = initF.y + initF.h - newH
                    elseif e.bottom then
                        newH = max(MIN_WIN_H, initF.h + dragState.totalDY)
                    end
                    pcall(dragState.window.setFrame, dragState.window, { x = newX, y = newY, w = newW, h = newH })
                end
                dragState.resizeTimer:stop()
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

    -- ── Right mouse down: Hyper+right-drag = resize from nearest corner ───────
    -- Divides the window into four quadrants; the quadrant the cursor is in
    -- determines which corner gets dragged. Works from anywhere in the window.
    elseif eventType == EV_RDOWN then
        dragState = {}
        if not isHyper() then return end
        local pos = event:location()
        local win = getWindowAtPoint(pos, RESIZE_MARGIN)
        if not (win and not win:isFullScreen()) then return true end

        local f     = win:frame()
        local winId = win:id()
        savedFrames[winId] = nil  -- discard any saved maximize state for this window

        local initF = { x = f.x, y = f.y, w = f.w, h = f.h }
        dragState = {
            window       = win,
            isResize     = true,
            edges        = quadrantEdges(pos, f),
            isCmdDrag    = true,
            didDrag      = false,
            initMouseX   = pos.x,
            initMouseY   = pos.y,
            initFrame    = initF,
            canvasFrame  = initF,
            resizeCanvas = makeResizeCanvas(initF),
        }
        return true

    -- ── Right mouse drag: update resize canvas ────────────────────────────────
    elseif eventType == EV_RDRAG then
        if not dragState.window or not dragState.isResize then return end
        dragState.didDrag = true

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
            newX = initF.x + initF.w - newW
        elseif e.right then
            newW = max(MIN_WIN_W, initF.w + totalDX)
        end

        if e.top then
            newH = max(MIN_WIN_H, initF.h - totalDY)
            newY = initF.y + initF.h - newH
        elseif e.bottom then
            newH = max(MIN_WIN_H, initF.h + totalDY)
        end

        local cf = { x = newX, y = newY, w = newW, h = newH }
        dragState.resizeCanvas:frame(cf)
        dragState.canvasFrame = cf
        return true

    -- ── Right mouse up: commit canvas frame to window ─────────────────────────
    elseif eventType == EV_RUP then
        if dragState.window and dragState.resizeCanvas then
            if dragState.didDrag then
                pcall(dragState.window.setFrame, dragState.window, dragState.canvasFrame)
            end
            deleteResizeCanvas(dragState.resizeCanvas)
            dragState = {}
            return true
        end

    -- ── Scroll: Hyper + two-finger scroll = resize from nearest corner ────────
    -- Each scroll event applies directly to the current frame (no canvas needed).
    -- Quadrant under the cursor determines which corner is being resized.
    elseif eventType == EV_SCROLL then
        if not isHyper() then return end
        local pos = event:location()
        -- Reuse the locked target if mid-gesture; otherwise find by position.
        -- The lock prevents losing the window when it shrinks past the cursor.
        local win = scrollTarget.win or getWindowAtPoint(pos, RESIZE_MARGIN)
        if not (win and not win:isFullScreen()) then return true end

        local dx = event:getProperty(props.scrollWheelEventPointDeltaAxis2)
        local dy = event:getProperty(props.scrollWheelEventPointDeltaAxis1)
        if dx == 0 and dy == 0 then return true end

        -- On the first real scroll event: snapshot frame and lock edges.
        -- Edges are locked so the resize direction can't flip as the window grows/shrinks.
        if not scrollTarget.win then
            local f = win:frame()
            scrollTarget.win       = win
            scrollTarget.edges     = quadrantEdges(pos, f)
            scrollTarget.initFrame = { x = f.x, y = f.y, w = f.w, h = f.h }
            scrollTarget.totalDX   = 0
            scrollTarget.totalDY   = 0
            scrollTarget.dirty     = false
            -- 60fps timer flushes accumulated deltas to setFrame independently of the
            -- event tap. This decouples the tap from slow app redraws (Xcode, Reminders)
            -- so the event queue never backs up — same principle as setTopLeft for move.
            scrollTarget.updateTimer = hs.timer.doEvery(1/60, function()
                if not scrollTarget.dirty then return end
                scrollTarget.dirty = false
                local e     = scrollTarget.edges
                local initF = scrollTarget.initFrame
                local newX  = initF.x
                local newY  = initF.y
                local newW  = initF.w
                local newH  = initF.h
                if e.left then
                    newW = max(MIN_WIN_W, initF.w - scrollTarget.totalDX)
                    newX = initF.x + initF.w - newW
                elseif e.right then
                    newW = max(MIN_WIN_W, initF.w + scrollTarget.totalDX)
                end
                if e.top then
                    newH = max(MIN_WIN_H, initF.h - scrollTarget.totalDY)
                    newY = initF.y + initF.h - newH
                elseif e.bottom then
                    newH = max(MIN_WIN_H, initF.h + scrollTarget.totalDY)
                end
                pcall(scrollTarget.win.setFrame, scrollTarget.win, { x = newX, y = newY, w = newW, h = newH })
            end)
        end

        -- Accumulate total scroll delta from the initial frame — the timer reads this.
        scrollTarget.totalDX = scrollTarget.totalDX + dx * SCROLL_RESIZE_SPEED
        scrollTarget.totalDY = scrollTarget.totalDY + dy * SCROLL_RESIZE_SPEED
        scrollTarget.dirty   = true

        -- Reset the release timer; on expiry stop the update timer and clean up.
        if scrollTarget.releaseTimer then scrollTarget.releaseTimer:stop() end
        scrollTarget.releaseTimer = hs.timer.doAfter(0.3, function()
            if scrollTarget.updateTimer then scrollTarget.updateTimer:stop() end
            scrollTarget = { win = nil, releaseTimer = nil, updateTimer = nil, edges = nil, initFrame = nil, totalDX = 0, totalDY = 0, dirty = false }
        end)
        return true
    end
end)

_G.windowDragger:start()
