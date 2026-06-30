package.loaded["modules.clipboard_manager"] = nil

-- Lightweight clipboard history. Text-only and in-memory on purpose; images,
-- rich text, and blob caches turn a tiny helper into a memory sink quickly.

if _G.clipboardMgrTimer  then _G.clipboardMgrTimer:stop() end
if _G.clipboardMgrHotkey then _G.clipboardMgrHotkey:delete() end
if _G.clipboardMgrChooser then _G.clipboardMgrChooser:delete() end
if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
if _G.clipboardMgrWebview then _G.clipboardMgrWebview:delete() end

local pb       = hs.pasteboard
local webview  = hs.webview
local eventtap = hs.eventtap
local keycodes = hs.keycodes

local MAX_ITEMS = 50
local POLL      = 0.5
local HYPER     = { "cmd", "ctrl", "alt", "shift" }

local PANEL_W = 920
local PANEL_H = 540
local VISIBLE_ROWS = 7

local history = _G.clipboardMgrHistory or {}
_G.clipboardMgrHistory = history

local query = ""
local selected = 1
local filtered = {}
local panelVisible = false

local function oneLine(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeText(s)
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, n)
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end

local function htmlEscape(s)
    return (s:gsub("&", "&amp;")
             :gsub("<", "&lt;")
             :gsub(">", "&gt;")
             :gsub('"', "&quot;")
             :gsub("'", "&#39;"))
end

local function dropLastChar(s)
    local i = utf8 and utf8.offset(s, -1)
    if i then return s:sub(1, i - 1) end
    return s:sub(1, -2)
end

local function selectedHistoryIndex()
    return filtered[selected]
end

local function updateFiltered()
    filtered = {}
    local q = query:lower()

    for i, text in ipairs(history) do
        if q == "" or text:lower():find(q, 1, true) or oneLine(text):lower():find(q, 1, true) then
            table.insert(filtered, i)
        end
    end

    if #filtered == 0 then
        selected = 1
    elseif selected > #filtered then
        selected = #filtered
    elseif selected < 1 then
        selected = 1
    end
end

local function pushText(text)
    if not text or text == "" then return end
    text = normalizeText(text)
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

local function itemMeta(text)
    local lines = 1
    for _ in text:gmatch("\n") do lines = lines + 1 end
    if lines > 1 then return tostring(lines) .. " lines" end
    return tostring(#text) .. " chars"
end

local function renderHTML()
    updateFiltered()

    local selectedText = ""
    local selectedTitle = "Clipboard"
    local idx = selectedHistoryIndex()
    if idx then
        selectedText = history[idx]
        selectedTitle = clip(oneLine(selectedText), 72)
    end

    local rows = {}
    local firstRow = 1
    if #filtered > VISIBLE_ROWS then
        firstRow = math.max(1, math.min(selected - 3, #filtered - VISIBLE_ROWS + 1))
    end
    local lastRow = math.min(#filtered, firstRow + VISIBLE_ROWS - 1)

    for rowIndex = firstRow, lastRow do
        local historyIndex = filtered[rowIndex]
        local text = history[historyIndex]
        local class = rowIndex == selected and "row selected" or "row"
        rows[#rows + 1] = string.format(
            '<div class="%s"><div class="row-title">%s</div><div class="row-meta">%s</div></div>',
            class,
            htmlEscape(clip(oneLine(text), 96)),
            htmlEscape(itemMeta(text))
        )
    end

    if #rows == 0 then
        rows[#rows + 1] = '<div class="empty">No clipboard items</div>'
    end

    local queryText = query ~= "" and htmlEscape(query) or "Clipboard history"
    local countText = #filtered > 0 and tostring(selected) .. " of " .. tostring(#filtered) or "0 items"
    local preview = selectedText ~= "" and htmlEscape(selectedText) or "No preview"

    return [[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
:root {
  color-scheme: light dark;
  --bg: rgba(246, 246, 246, 0.86);
  --sidebar: rgba(234, 234, 234, 0.74);
  --line: rgba(0, 0, 0, 0.12);
  --text: #1d1d1f;
  --muted: rgba(60, 60, 67, 0.68);
  --selected: #007aff;
  --selected-muted: rgba(255, 255, 255, 0.78);
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: rgba(32, 32, 34, 0.88);
    --sidebar: rgba(45, 45, 48, 0.74);
    --line: rgba(255, 255, 255, 0.12);
    --text: #f5f5f7;
    --muted: rgba(235, 235, 245, 0.62);
    --selected: #0a84ff;
    --selected-muted: rgba(255, 255, 255, 0.78);
  }
}

html, body {
  background: transparent;
  margin: 0;
  overflow: hidden;
  width: 100%;
  height: 100%;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  letter-spacing: 0;
  -webkit-user-select: none;
}

.panel {
  box-sizing: border-box;
  display: grid;
  grid-template-columns: 340px 1fr;
  height: calc(100vh - 24px);
  margin: 12px;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: var(--bg);
  color: var(--text);
  box-shadow: 0 22px 70px rgba(0, 0, 0, 0.28);
  backdrop-filter: saturate(180%) blur(28px);
}

.sidebar {
  min-width: 0;
  overflow: hidden;
  border-right: 1px solid var(--line);
  background: var(--sidebar);
}

.query {
  box-sizing: border-box;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
  height: 58px;
  padding: 0 18px;
  border-bottom: 1px solid var(--line);
  color: var(--muted);
  font-size: 14px;
  font-weight: 500;
}

.query-title,
.query-count {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.query-title {
  min-width: 0;
}

.query-count {
  flex: 0 0 auto;
  font-size: 12px;
}

.rows {
  height: calc(100% - 58px);
  overflow: hidden;
  padding: 8px;
}

.row {
  box-sizing: border-box;
  height: 58px;
  padding: 9px 11px;
  border-radius: 9px;
  overflow: hidden;
}

.row + .row {
  margin-top: 2px;
}

.row-title {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
  font-weight: 500;
  line-height: 18px;
}

.row-meta {
  margin-top: 3px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--muted);
  font-size: 12px;
  line-height: 16px;
}

.selected {
  background: var(--selected);
  color: #fff;
}

.selected .row-meta {
  color: var(--selected-muted);
}

.empty {
  padding: 18px 11px;
  color: var(--muted);
  font-size: 13px;
}

.preview {
  box-sizing: border-box;
  min-width: 0;
  padding: 26px 30px 30px;
}

.preview-title {
  margin-bottom: 18px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--muted);
  font-size: 13px;
  font-weight: 600;
}

.preview-body {
  box-sizing: border-box;
  height: calc(100% - 34px);
  overflow: auto;
  color: var(--text);
  font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
  font-size: 13px;
  line-height: 1.55;
  white-space: pre-wrap;
  word-break: break-word;
  -webkit-user-select: text;
}
</style>
</head>
<body>
  <main class="panel">
    <section class="sidebar">
      <div class="query"><span class="query-title">]] .. queryText .. [[</span><span class="query-count">]] .. countText .. [[</span></div>
      <div class="rows">]] .. table.concat(rows, "\n") .. [[</div>
    </section>
    <section class="preview">
      <div class="preview-title">]] .. htmlEscape(selectedTitle) .. [[</div>
      <div class="preview-body">]] .. preview .. [[</div>
    </section>
  </main>
</body>
</html>
]]
end

local function panelFrame()
    local f = hs.screen.mainScreen():frame()
    local w = math.min(PANEL_W, f.w - 64)
    local h = math.min(PANEL_H, f.h - 64)
    return {
        x = math.floor(f.x + (f.w - w) / 2),
        y = math.floor(f.y + (f.h - h) / 2),
        w = math.floor(w),
        h = math.floor(h),
    }
end

local function renderPanel()
    if not _G.clipboardMgrWebview then return end
    _G.clipboardMgrWebview:html(renderHTML())
end

local function hidePanel()
    panelVisible = false
    if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
    if _G.clipboardMgrWebview then _G.clipboardMgrWebview:hide(0.08) end
end

local function chooseSelected()
    local idx = selectedHistoryIndex()
    if not idx then return end
    pb.setContents(history[idx])
    hidePanel()
end

local function moveSelection(delta)
    updateFiltered()
    if #filtered == 0 then return end
    selected = math.max(1, math.min(#filtered, selected + delta))
    renderPanel()
end

local function deleteSelected()
    local idx = selectedHistoryIndex()
    if not idx then return end
    table.remove(history, idx)
    renderPanel()
end

local function buildPanel()
    if _G.clipboardMgrWebview then return end

    _G.clipboardMgrWebview = webview.new(panelFrame())
        :windowStyle(0)
        :allowTextEntry(false)
        :allowNewWindows(false)
        :transparent(true)
        :shadow(true)
        :level(hs.drawing.windowLevels.floating)
        :windowTitle("Clipboard History")
        :windowCallback(function(action)
            if action == "closing" then
                panelVisible = false
                if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
                _G.clipboardMgrWebview = nil
            end
        end)
end

local function showPanel()
    if panelVisible and _G.clipboardMgrWebview and _G.clipboardMgrWebview:isVisible() then
        hidePanel()
        return
    end

    query = ""
    selected = 1
    buildPanel()
    _G.clipboardMgrWebview:frame(panelFrame())
    renderPanel()
    _G.clipboardMgrWebview:show(0.08):bringToFront(false)
    panelVisible = true
    if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:start() end
end

local lastChange = pb.changeCount()

_G.clipboardMgrTimer = hs.timer.doEvery(POLL, function()
    local c = pb.changeCount()
    if c == lastChange then return end
    lastChange = c

    local text = pb.readString()
    if text then
        pushText(text)
        if panelVisible then renderPanel() end
    end
end):start()

_G.clipboardMgrKeyTap = eventtap.new({ eventtap.event.types.keyDown }, function(e)
    if not panelVisible then return false end

    local key = keycodes.map[e:getKeyCode()]
    local flags = e:getFlags()
    local hasCommand = flags.cmd or flags.ctrl or flags.alt

    if key == "escape" then
        hidePanel()
        return true
    elseif key == "down" then
        moveSelection(1)
        return true
    elseif key == "up" then
        moveSelection(-1)
        return true
    elseif key == "pagedown" then
        moveSelection(7)
        return true
    elseif key == "pageup" then
        moveSelection(-7)
        return true
    elseif key == "home" then
        selected = 1
        renderPanel()
        return true
    elseif key == "end" then
        updateFiltered()
        selected = math.max(1, #filtered)
        renderPanel()
        return true
    elseif key == "return" then
        chooseSelected()
        return true
    elseif key == "delete" and flags.cmd then
        deleteSelected()
        return true
    elseif key == "delete" then
        query = dropLastChar(query)
        selected = 1
        renderPanel()
        return true
    elseif key == "c" and flags.cmd then
        chooseSelected()
        return true
    end

    if not hasCommand then
        local ch = e:getCharacters(true)
        if ch and ch ~= "" and ch:match("%C") then
            query = query .. ch
            selected = 1
            renderPanel()
            return true
        end
    end

    return true
end)

_G.clipboardMgrHotkey = hs.hotkey.bind(HYPER, "v", showPanel)
_G.clipboardMgrShow = showPanel
