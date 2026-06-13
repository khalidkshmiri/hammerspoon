package.loaded["modules.clipboard_ring"] = nil

-- ── Clipboard ring ────────────────────────────────────────────────────────────
-- Keeps the last N text clips. Hyper+V opens a searchable list; pick one to paste
-- it. The newest clip is always on top, so Hyper+V then Return pastes the previous
-- copy — a quick "paste the thing before this thing" without losing the current
-- clipboard.
--
-- Plays nice with paste_manager: entries are plain text only (no rich UTIs), so the
-- Cmd+V we post falls through paste_manager's native path untouched. Temporary
-- writes tagged transient/concealed by paste_manager are skipped, so the ring never
-- records the strip-and-restore churn.

if _G.clipboardRingTimer   then _G.clipboardRingTimer:stop()  end
if _G.clipboardRingChooser then _G.clipboardRingChooser:delete() end

local pb       = hs.pasteboard
local eventtap = hs.eventtap

local MAX_ENTRIES = 25
local POLL        = 0.5  -- seconds between change-count checks (no native pasteboard callback)
local HYPER       = { "cmd", "ctrl", "alt", "shift" }

-- nspasteboard.org markers: a clip carrying either is a clipboard-manager's own
-- scratch write (e.g. paste_manager stripping rich text) — never record it.
local SKIP_UTIS = {
    ["org.nspasteboard.ConcealedType"] = true,
    ["org.nspasteboard.TransientType"] = true,
}

-- Persist across reloads so the ring survives a config save.
_G.clipboardRing = _G.clipboardRing or {}
local ring = _G.clipboardRing

local lastChange = pb.changeCount()

local function shouldSkip()
    for _, uti in ipairs(pb.contentTypes() or {}) do
        if SKIP_UTIS[uti] then return true end
    end
    return false
end

local function pushClip(str)
    if not str or str == "" then return end
    -- Move an existing identical clip to the top instead of duplicating.
    for i, v in ipairs(ring) do
        if v == str then table.remove(ring, i); break end
    end
    table.insert(ring, 1, str)
    while #ring > MAX_ENTRIES do table.remove(ring) end
end

_G.clipboardRingTimer = hs.timer.doEvery(POLL, function()
    local c = pb.changeCount()
    if c == lastChange then return end
    lastChange = c
    if shouldSkip() then return end
    pushClip(pb.readString())
end)
_G.clipboardRingTimer:start()

-- Single space collapses whitespace so multi-line clips show on one chooser row.
local function oneLine(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

_G.clipboardRingChooser = hs.chooser.new(function(choice)
    if not choice then return end
    pb.setContents(ring[choice.index])
    -- Plain-text contents → paste_manager's Cmd+V handler passes this straight through.
    eventtap.keyStroke({ "cmd" }, "v", 0)
end)
_G.clipboardRingChooser:searchSubText(true)

hs.hotkey.bind(HYPER, "v", function()
    local choices = {}
    for i, v in ipairs(ring) do
        choices[#choices + 1] = {
            text    = oneLine(v),
            subText = (#v > 80) and (v:sub(1, 80) .. "…") or nil,
            index   = i,
        }
    end
    _G.clipboardRingChooser:choices(choices)
    _G.clipboardRingChooser:show()
end)
