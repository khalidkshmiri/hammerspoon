package.loaded["modules.horizontal_scroll"] = nil

-- ── Shift + scroll = horizontal scroll, anywhere ──────────────────────────────
-- Hold Shift while scrolling vertically and it scrolls horizontally instead. Works
-- in apps that don't honour Shift+scroll themselves (timelines, wide tables, code).
--
-- LinearMouse coexistence: this only fires while Shift is held — a gesture LinearMouse
-- isn't remapping — and it re-posts a *new* scroll event tagged with MAGIC so our own
-- tap ignores it (no feedback loop). LinearMouse's own (unshifted) handling is untouched.

if _G.horizontalScrollTap then _G.horizontalScrollTap:stop() end

local eventtap = hs.eventtap
local types    = eventtap.event.types
local props    = eventtap.event.properties

local MAGIC = 0x48535352 -- "HSSR" — marks our synthetic horizontal event

_G.horizontalScrollTap = eventtap.new({ types.scrollWheel }, function(e)
    -- Ignore the event we re-post below.
    if e:getProperty(props.eventSourceUserData) == MAGIC then return false end

    local f = e:getFlags()
    -- Shift only. Other modifiers (e.g. Hyper used by window_manager's resize-scroll)
    -- must fall through so we don't hijack those gestures.
    if not f.shift or f.cmd or f.ctrl or f.alt then return false end

    -- Vertical wheel delta to redirect. Continuous (pixel) and line deltas both exist;
    -- read the line delta to rebuild an equivalent horizontal event.
    local dyLine = e:getProperty(props.scrollWheelEventDeltaAxis1)
    if dyLine == 0 then return false end

    -- Build a horizontal scroll: axis-2 carries the redirected vertical delta.
    -- isContinuous=false yields a standard line-based wheel event apps understand.
    local ev = eventtap.event.newScrollEvent({ dyLine, 0 }, {}, "line")
    ev:setProperty(props.eventSourceUserData, MAGIC)
    ev:post()

    return true -- swallow the original vertical event
end)

_G.horizontalScrollTap:start()
