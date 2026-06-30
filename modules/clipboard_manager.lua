package.loaded["modules.clipboard_manager"] = nil

-- ── Lightweight clipboard history ─────────────────────────────────────────────
-- ponytail: text-only and in-memory on purpose; images/rich text/blob caches are
-- the fastest way to turn a tiny helper into a memory sink.

if _G.clipboardMgrTimer  then _G.clipboardMgrTimer:stop() end
if _G.clipboardMgrHotkey then _G.clipboardMgrHotkey:delete() end
if _G.clipboardMgrChooser then _G.clipboardMgrChooser:delete() end

local chooser = hs.chooser
local pb      = hs.pasteboard

local MAX_ITEMS = 50
local POLL      = 0.5
local HYPER     = { "cmd", "ctrl", "alt", "shift" }

local history = _G.clipboardMgrHistory or {}
_G.clipboardMgrHistory = history

local function oneLine(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, n)
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end

local function pushText(text)
    if not text or text == "" then return end
    text = oneLine(text)
    if text == "" then return end

    for i, v in ipairs(history) do
        if v == text then
            table.remove(history, i)
            break
        end
    end

    table.insert(history, 1, text)
    while #history > MAX_ITEMS do table.remove(history) end
end

local function buildChoices()
    local choices = {}
    for i, text in ipairs(history) do
        choices[i] = {
            text = clip(text, 140),
            subText = text,
            idx = i,
        }
    end
    return choices
end

local function refreshChooser()
    if _G.clipboardMgrChooser then
        _G.clipboardMgrChooser:choices(buildChoices())
    end
end

local lastChange = pb.changeCount()

_G.clipboardMgrTimer = hs.timer.doEvery(POLL, function()
    local c = pb.changeCount()
    if c == lastChange then return end
    lastChange = c

    local text = pb.readString()
    if text then
        pushText(text)
        refreshChooser()
    end
end):start()

local function onChoose(choice)
    if not choice then return end
    local text = history[choice.idx]
    if text then pb.setContents(text) end
end

_G.clipboardMgrChooser = chooser.new(onChoose)
_G.clipboardMgrChooser:placeholderText("Clipboard history")
_G.clipboardMgrChooser:choices(buildChoices())

local function showChooser()
    refreshChooser()
    _G.clipboardMgrChooser:show()
end

_G.clipboardMgrHotkey = hs.hotkey.bind(HYPER, "v", showChooser)

_G.clipboardMgrShow = showChooser
