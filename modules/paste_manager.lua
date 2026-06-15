package.loaded["modules.paste_manager"] = nil

-- ── Plain-paste manager ───────────────────────────────────────────────────────
-- Cmd+V        → paste WITHOUT formatting (strips rich text)
-- Cmd+Opt+V    → paste WITH formatting (native paste)
--
-- Design goals (see plan): never corrupt files/images on the clipboard, and never
-- pollute clipboard-history watchers (Raycast, macOS/Spotlight clipboard) with the
-- temporary plain-text we put on the board while stripping.

if _G.pasteManagerTap then _G.pasteManagerTap:stop() end

local eventtap = hs.eventtap
local pb       = hs.pasteboard
local types    = eventtap.event.types
local props    = eventtap.event.properties

-- Magic tag stamped onto our own synthetic Cmd+V so the tap ignores it (no recursion).
-- Order-independent, unlike a Lua boolean flag which can race with async event delivery.
local MAGIC = 0x504C4149 -- "PLAI"

-- Rich-text UTIs: presence of any of these means there IS formatting worth stripping.
local RICH_UTIS = {
    ["public.rtf"]           = true,
    ["public.html"]          = true,
    ["com.apple.webarchive"] = true,
    ["public.rtfd"]          = true,
    ["com.apple.flat-rtfd"]  = true,
}

local PLAIN_UTI = "public.utf8-plain-text"

-- nspasteboard.org markers honored by well-behaved clipboard managers to SKIP an entry.
-- We tag both our temporary plain write and the restore write so neither is recorded;
-- the user's real copy is already in history from when they actually copied.
local CONCEALED = "org.nspasteboard.ConcealedType"
local TRANSIENT = "org.nspasteboard.TransientType"

-- Does the front pasteboard item contain rich text we should strip?
local function clipboardHasRichText()
    for _, uti in ipairs(pb.contentTypes() or {}) do
        if RICH_UTIS[uti] then return true end
    end
    return false
end

-- Fire a native Cmd+V that our own tap will pass straight through (tagged with MAGIC).
local function postTaggedPaste()
    local down = eventtap.event.newKeyEvent({ "cmd" }, "v", true)
    local up   = eventtap.event.newKeyEvent({ "cmd" }, "v", false)
    down:setProperty(props.eventSourceUserData, MAGIC)
    up:setProperty(props.eventSourceUserData, MAGIC)
    down:post()
    up:post()
end

_G.pasteManagerTap = eventtap.new({ types.keyDown }, function(e)
    -- Ignore our own synthetic paste (prevents recursion / double-strip).
    if e:getProperty(props.eventSourceUserData) == MAGIC then return false end

    if hs.keycodes.map[e:getKeyCode()] ~= "v" then return false end

    local f = e:getFlags()
    if not f.cmd or f.ctrl or f.shift then return false end

    if f.alt then
        -- Finder uses Cmd+Opt+V to *move* (cut-paste) files/folders.
        -- Pass the event through untouched so the move actually happens.
        local frontApp = hs.application.frontmostApplication()
        if frontApp and frontApp:bundleID() == "com.apple.finder" then
            return false
        end
        -- All other apps: Cmd+Opt+V → formatted paste. Swallow original and
        -- re-issue a clean native paste (Option stripped so it doesn't trigger
        -- app-specific Opt+V shortcuts in editors, etc.).
        -- Clipboard is never touched, so files/images/rich text all paste as-is.
        postTaggedPaste()
        return true
    end

    -- Cmd+V: only intervene when there is actual formatting to strip. Files, images,
    -- and plain-text-only clipboards fall through to the unmodified native paste.
    if not clipboardHasRichText() then return false end

    local plain = pb.readString()
    if not plain then return false end

    -- Snapshot every representation so we can restore the exact original afterward.
    local snap = pb.readAllData()

    -- Put plain text on the board, tagged so clipboard managers skip recording it.
    pb.writeAllData({ [PLAIN_UTI] = plain, [CONCEALED] = "", [TRANSIENT] = "" })

    postTaggedPaste()

    -- Restore the original rich clipboard after the paste lands, so Cmd+Opt+V still
    -- works afterward. Tag the restore transient too, so history watchers don't log a
    -- duplicate of what the user already copied.
    hs.timer.doAfter(0.15, function()
        snap[CONCEALED] = ""
        snap[TRANSIENT] = ""
        pb.writeAllData(snap)
    end)

    return true -- we handled this Cmd+V via the tagged paste above
end)

_G.pasteManagerTap:start()
