package.loaded["modules.clipboard_manager"] = nil

-- Clipboard history with a native macOS-style panel. The history keeps raw
-- pasteboard representations where Hammerspoon exposes them, so pasting/copying
-- can preserve files, images, URLs, RTF/HTML, and plain text instead of flattening
-- everything into strings.

if _G.clipboardMgrTimer  then _G.clipboardMgrTimer:stop() end
if _G.clipboardMgrHotkey then _G.clipboardMgrHotkey:delete() end
if _G.clipboardMgrChooser then _G.clipboardMgrChooser:delete() end
if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
if _G.clipboardMgrMouseTap then _G.clipboardMgrMouseTap:stop() end
if _G.clipboardMgrWebview then _G.clipboardMgrWebview:delete() end
if _G.clipboardMgrQLTask and _G.clipboardMgrQLTask:isRunning() then _G.clipboardMgrQLTask:terminate() end

local pb       = hs.pasteboard
local webview  = hs.webview
local eventtap = hs.eventtap
local keycodes = hs.keycodes
local task     = hs.task

local MAX_ITEMS = 50
local POLL      = 0.5
local HYPER     = { "cmd", "ctrl", "alt", "shift" }

local PANEL_W = 680
local PANEL_H = 430
local DETAIL_W = 980
local VISIBLE_ROWS = 8
local QUERY_H = 58
local SETTINGS_KEY = "clipboardMgr.history.v2"
local CACHE_DIR = hs.fs.temporaryDirectory() .. "/hammerspoon-clipboard-manager"

local RICH_UTIS = {
    ["public.rtf"] = true,
    ["public.html"] = true,
    ["com.apple.webarchive"] = true,
    ["public.rtfd"] = true,
    ["com.apple.flat-rtfd"] = true,
}

local IMAGE_UTIS = {
    ["public.png"] = true,
    ["public.tiff"] = true,
    ["public.jpeg"] = true,
    ["public.heic"] = true,
    ["com.apple.icns"] = true,
}

local MARKDOWN_UTIS = {
    ["net.daringfireball.markdown"] = true,
    ["public.markdown"] = true,
    ["text/markdown"] = true,
}

-- Hammerspoon reloads wipe Lua userdata, so the stored history must be plain Lua
-- data plus file paths. Images are mirrored into CACHE_DIR so a config reload does
-- not make existing image entries unusable.
hs.fs.mkdir(CACHE_DIR)

local rawHistory = _G.clipboardMgrHistory or hs.settings.get(SETTINGS_KEY) or {}
local history = rawHistory
_G.clipboardMgrHistory = history
_G.clipboardMgrTasks = _G.clipboardMgrTasks or {}

local query = ""
local selected = 1
local filtered = {}
local panelVisible = false
local detailMode = nil
local statusText = ""
local previousWindow = nil
local panelHasInput = false
local draggingPanel = false
local dragStartMouse = nil
local dragStartFrame = nil
local panelFrameCache = nil
local cmdHeld = false
local visibleFirst = 1
local renderPanel

local function oneLine(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeText(s)
    if not s then return nil end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, n)
    if not s then return "" end
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end

local function htmlEscape(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;")
             :gsub("<", "&lt;")
             :gsub(">", "&gt;")
             :gsub('"', "&quot;")
             :gsub("'", "&#39;"))
end

local function cssEscape(s)
    return htmlEscape(s):gsub("\n", " ")
end

local function dropLastChar(s)
    local i = utf8 and utf8.offset(s, -1)
    if i then return s:sub(1, i - 1) end
    return s:sub(1, -2)
end

local function hasUTI(types, lookup)
    for _, uti in ipairs(types or {}) do
        if lookup[uti] then return true end
    end
    return false
end

local function safeCall(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function setStatus(message)
    statusText = message or ""
    hs.timer.doAfter(1.2, function()
        if statusText == message then
            statusText = ""
            if panelVisible then renderPanel() end
        end
    end)
end

local function reportError(context, err)
    local message = "Clipboard manager " .. context .. " failed"
    print(message .. ": " .. tostring(err))
    hs.alert.show(message)
    setStatus(message)
end

-- Pasteboard/webview callbacks used to fail silently; surfacing the failure keeps
-- one unexpected clipboard format from forcing a full config reload to recover.
local function guarded(context, fn, fallback)
    local ok, result = xpcall(fn, debug.traceback)
    if ok then return result end
    reportError(context, result)
    return fallback
end

local function hasHyper(flags)
    return flags.cmd and flags.ctrl and flags.alt and flags.shift
end

local function asList(value)
    if value == nil then return {} end
    if type(value) == "table" then return value end
    return { value }
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function percentDecode(s)
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function percentEncodePath(s)
    return (s:gsub("([^%w%-%._~/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function fileURLToPath(url)
    if type(url) ~= "string" or not url:match("^file://") then return nil end
    local path = url:gsub("^file://localhost", ""):gsub("^file://", "")
    return percentDecode(path)
end

local function pathToFileURL(path)
    if type(path) ~= "string" then return "" end
    return "file://" .. percentEncodePath(path)
end

-- hs.pasteboard.readURL now returns NSURL objects as tables ({url=,filePath=}),
-- not strings. Flattening them here is the root fix: otherwise every file/URL
-- capture throws on the first string op (signature/setContents) and is dropped.
-- Prefer the resolved filePath: Finder hands multi-file copies as opaque
-- /.file/id= reference URLs, whose only usable form is the NSURL's POSIX path.
local function urlToString(u)
    if type(u) == "string" then return u end
    if type(u) ~= "table" then return nil end
    if type(u.filePath) == "string" and u.filePath ~= "" then return pathToFileURL(u.filePath) end
    return u.url
end

local function readURLStrings()
    local raw = safeCall(pb.readURL, true)
    local list = type(raw) == "table" and raw or {}
    if #list == 0 then
        local single = safeCall(pb.readURL)
        if single then list = { single } end
    end
    local out = {}
    for _, u in ipairs(list) do
        local s = urlToString(u)
        if s and s ~= "" then out[#out + 1] = s end
    end
    return out
end

local function appendUnique(list, value)
    if not value or value == "" then return end
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    table.insert(list, value)
end

local function extractFiles(types, urls)
    local files = {}

    for _, url in ipairs(urls or {}) do
        appendUnique(files, fileURLToPath(url))
    end

    -- Finder still exposes copied files through legacy pasteboard UTIs on some
    -- macOS paths. Reading these explicitly keeps folders/files visible even when
    -- readURL() returns nil for the current pasteboard owner.
    local filenames = safeCall(pb.readPListForUTI, nil, "NSFilenamesPboardType")
        or safeCall(pb.readPListForUTI, nil, "com.apple.pasteboard.promised-file-url")
    if type(filenames) == "table" then
        for _, path in ipairs(filenames) do appendUnique(files, path) end
    elseif type(filenames) == "string" then
        appendUnique(files, filenames)
    end

    for _, uti in ipairs(types or {}) do
        if uti == "public.file-url" or uti == "NSURLPboardType" then
            local raw = safeCall(pb.readDataForUTI, nil, uti)
            if type(raw) == "string" then
                for url in raw:gmatch("file://[^\0\r\n]+") do
                    appendUnique(files, fileURLToPath(url))
                end
            end
        end
    end

    return files
end

local function looksLikeURL(text)
    return type(text) == "string" and text:match("^[%w+.-]+://%S+$") ~= nil
end

local function looksLikeMarkdown(text)
    if type(text) ~= "string" then return false end
    return text:match("\n#%s")
        or text:match("^#%s")
        or text:match("\n[-*+]%s")
        or text:match("```")
        or text:match("%[[^%]]+%]%([^%)]+%)")
        or text:match("\n>%s")
end

local function desktopPath()
    return (os.getenv("HOME") or "~") .. "/Desktop"
end

local function timestamp()
    return os.date("%Y-%m-%d %H.%M.%S")
end

local function sanitizeFilename(name)
    name = oneLine(tostring(name or "Clipboard Item"))
    name = name:gsub("[/:]", "-"):gsub("[^%w%s%._%-]", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "Clipboard Item" end
    return clip(name, 72)
end

local function uniquePath(path)
    if not hs.fs.attributes(path) then return path end
    local base, ext = path:match("^(.*)(%.[^%.]+)$")
    if not base then base, ext = path, "" end
    for i = 2, 99 do
        local candidate = string.format("%s %d%s", base, i, ext)
        if not hs.fs.attributes(candidate) then return candidate end
    end
    return path
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data or "")
    f:close()
    return true
end

local function startTask(path, args)
    local t = task.new(path, nil, nil, args)
    if not t then return false end
    table.insert(_G.clipboardMgrTasks, t)
    t:start()
    return true
end

local function saveImageCache(image)
    if not image then return nil end
    local path = uniquePath(CACHE_DIR .. "/Clipboard Image " .. timestamp() .. ".png")
    if image:saveToFile(path, true, "PNG") then return path end
    return nil
end

local function serializeEntry(item)
    if not item then return nil end
    return {
        kind = item.kind,
        title = item.title,
        subtitle = item.subtitle,
        text = item.text,
        urls = item.urls or {},
        files = item.files or {},
        imageFile = item.imageFile,
        types = item.types or {},
        signature = item.signature,
        created = item.created,
    }
end

local function saveHistory()
    local stored = {}
    for _, item in ipairs(history) do
        local serial = serializeEntry(item)
        if serial then table.insert(stored, serial) end
    end
    hs.settings.set(SETTINGS_KEY, stored)
end

local function signatureFor(data, types, text, urls)
    local parts = {}
    for _, uti in ipairs(sortedKeys(data or {})) do
        local value = data[uti]
        parts[#parts + 1] = uti .. ":" .. tostring(type(value) == "string" and #value or 0) .. ":" .. tostring(value):sub(1, 64)
    end
    for _, uti in ipairs(types or {}) do parts[#parts + 1] = "type:" .. uti end
    for _, url in ipairs(urls or {}) do parts[#parts + 1] = "url:" .. url end
    if text then parts[#parts + 1] = "text:" .. text:sub(1, 256) end
    return table.concat(parts, "|")
end

local function makeEntryFromText(text)
    text = normalizeText(text)
    if not text or text == "" then return nil end
    local kind = looksLikeURL(text) and "url" or (looksLikeMarkdown(text) and "markdown" or "text")
    return {
        kind = kind,
        title = clip(oneLine(text), 96),
        subtitle = kind == "markdown" and "Markdown text" or (kind == "url" and "URL" or "Plain text"),
        text = text,
        types = { "public.utf8-plain-text" },
        data = { ["public.utf8-plain-text"] = text },
        urls = kind == "url" and { text } or {},
        files = {},
        signature = "text:" .. text,
        created = os.time(),
    }
end

local function makeEntryFromPasteboard()
    local types = safeCall(pb.contentTypes) or {}
    local data = safeCall(pb.readAllData) or {}
    local text = normalizeText(safeCall(pb.readString))
    local image = safeCall(pb.readImage)
    local styledText = safeCall(pb.readStyledText)
    local urls = readURLStrings()
    local files = extractFiles(types, urls)

    local kind = "text"
    if #files > 0 then
        kind = "file"
    elseif image or hasUTI(types, IMAGE_UTIS) then
        kind = "image"
    elseif hasUTI(types, MARKDOWN_UTIS) or looksLikeMarkdown(text) then
        kind = "markdown"
    elseif hasUTI(types, RICH_UTIS) then
        kind = "richtext"
    elseif #urls > 0 or looksLikeURL(text) then
        kind = "url"
    end

    if not text and kind == "url" and urls[1] then text = urls[1] end
    if not text and kind == "file" then text = table.concat(files, "\n") end

    local title = "Clipboard Item"
    local subtitle = "Pasteboard item"
    local imageURL = nil
    local imageFile = nil

    if kind == "file" then
        title = #files == 1 and (files[1]:match("[^/]+$") or files[1]) or tostring(#files) .. " files"
        subtitle = table.concat(files, ", ")
    elseif kind == "image" then
        local size = image and image:size() or nil
        title = "Image"
        subtitle = size and string.format("%dx%d image", size.w, size.h) or "Image"
        imageURL = image and image:encodeAsURLString(true, "PNG") or nil
        imageFile = saveImageCache(image)
    elseif kind == "richtext" then
        title = text and clip(oneLine(text), 96) or "Rich text"
        subtitle = hasUTI(types, { ["public.html"] = true }) and "HTML rich text" or "Rich text"
    elseif kind == "markdown" then
        title = text and clip(oneLine(text), 96) or "Markdown"
        subtitle = "Markdown text"
    elseif kind == "url" then
        title = text and clip(oneLine(text), 96) or (urls[1] or "URL")
        subtitle = "URL"
    elseif text and text ~= "" then
        title = clip(oneLine(text), 96)
        subtitle = "Plain text"
    else
        title = types[1] or "Clipboard Item"
        subtitle = "Unsupported pasteboard data"
    end

    local sig = signatureFor(data, types, text, urls)
    if sig == "" then return nil end

    return {
        kind = kind,
        title = title,
        subtitle = subtitle,
        text = text,
        styledText = styledText,
        image = image,
        imageURL = imageURL,
        imageFile = imageFile,
        urls = urls,
        files = files,
        types = types,
        data = data,
        signature = sig,
        created = os.time(),
    }
end

local function normalizeHistory()
    for i = #history, 1, -1 do
        local item = history[i]
        if type(item) == "string" then
            history[i] = makeEntryFromText(item)
        elseif type(item) == "table" then
            item.urls = item.urls or {}
            item.files = item.files or {}
            item.types = item.types or {}
            if item.kind == "image" and item.imageFile and not item.image then
                item.image = hs.image.imageFromPath(item.imageFile)
                item.imageURL = item.image and item.image:encodeAsURLString(true, "PNG") or nil
            end
            if not item.signature then
                item.signature = signatureFor(item.data, item.types, item.text, item.urls)
            end
        end
        if not history[i] then table.remove(history, i) end
    end
end

normalizeHistory()
saveHistory()

local function itemSearchText(item)
    return table.concat({
        item.title or "",
        item.subtitle or "",
        item.kind or "",
        item.text or "",
        table.concat(item.urls or {}, " "),
        table.concat(item.files or {}, " "),
    }, " "):lower()
end

local function selectedHistoryIndex()
    return filtered[selected]
end

local function selectedItem()
    local idx = selectedHistoryIndex()
    return idx and history[idx] or nil
end

local function updateFiltered()
    filtered = {}
    local q = query:lower()

    for i, item in ipairs(history) do
        if q == "" or itemSearchText(item):find(q, 1, true) then
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

local function pushEntry(item)
    if not item then return end

    for i, existing in ipairs(history) do
        if existing.signature == item.signature then
            table.remove(history, i)
            break
        end
    end

    table.insert(history, 1, item)
    while #history > MAX_ITEMS do table.remove(history) end
    saveHistory()
end

local function restoreClipboard(item)
    if not item then return false end

    -- Prefer typed Cocoa objects for formats that broke when restored as raw UTI
    -- blobs. Falling back to raw data is intentionally narrow so a failed complex
    -- restore does not clear the pasteboard and poison future clipboard captures.
    if item.kind == "file" and #(item.files or {}) > 0 then
        local urls = {}
        for _, file in ipairs(item.files) do
            if hs.fs.attributes(file) then table.insert(urls, hs.sharing.fileURL(file)) end
        end
        if #urls == 0 then return false end
        return safeCall(pb.writeObjects, urls) == true
    elseif item.kind == "image" and item.image then
        return safeCall(pb.writeObjects, item.image) == true
    elseif item.kind == "image" and item.imageFile then
        local image = hs.image.imageFromPath(item.imageFile)
        return image and safeCall(pb.writeObjects, image) == true or false
    elseif item.kind == "url" and (item.urls[1] or item.text) then
        return pb.setContents(item.urls[1] or item.text)
    elseif item.kind == "richtext" and item.styledText then
        return safeCall(pb.writeObjects, item.styledText) == true
    elseif item.kind == "richtext" and item.text then
        return pb.setContents(item.text)
    elseif item.text then
        return pb.setContents(item.text)
    end
    return false
end

local function actionStatus(message)
    setStatus(message)
end

local function focusPreviousWindow()
    if previousWindow and safeCall(function() return previousWindow:isStandard() end) then
        previousWindow:focus()
    end
end

local function postPasteForItem(item)
    local mods = item and item.kind == "richtext" and { "cmd", "alt" } or { "cmd" }
    if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
    focusPreviousWindow()
    eventtap.keyStroke(mods, "v", 0)
end

local function pasteItem(item, keepOpen)
    if not item or not restoreClipboard(item) then
        actionStatus("Could not restore clipboard item.")
        return
    end

    if keepOpen then
        postPasteForItem(item)
        hs.timer.doAfter(0.16, function()
            if panelVisible and _G.clipboardMgrWebview then
                _G.clipboardMgrWebview:bringToFront(false)
                if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:start() end
            end
        end)
    else
        panelVisible = false
        if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
        if _G.clipboardMgrWebview then _G.clipboardMgrWebview:hide(0.08) end
        hs.timer.doAfter(0.04, function() postPasteForItem(item) end)
    end
end

local function copyItem(item)
    if restoreClipboard(item) then
        actionStatus("Copied item to clipboard.")
    else
        actionStatus("Could not copy item.")
    end
end

local function writeItemToTemporaryFile(item)
    if not item then return nil end
    local dir = hs.fs.temporaryDirectory() .. "/hammerspoon-clipboard"
    hs.fs.mkdir(dir)
    local path

    if item.kind == "image" and item.image then
        path = uniquePath(dir .. "/Clipboard Image " .. timestamp() .. ".png")
        if item.image:saveToFile(path, true, "PNG") then return path end
    elseif item.kind == "markdown" then
        path = uniquePath(dir .. "/Clipboard Markdown " .. timestamp() .. ".md")
        if writeFile(path, item.text or "") then return path end
    elseif item.kind == "richtext" and item.data and item.data["public.rtf"] then
        path = uniquePath(dir .. "/Clipboard Rich Text " .. timestamp() .. ".rtf")
        if writeFile(path, item.data["public.rtf"]) then return path end
    elseif item.kind == "richtext" and item.data and item.data["public.html"] then
        path = uniquePath(dir .. "/Clipboard Rich Text " .. timestamp() .. ".html")
        if writeFile(path, item.data["public.html"]) then return path end
    else
        path = uniquePath(dir .. "/Clipboard Text " .. timestamp() .. ".txt")
        if writeFile(path, item.text or item.title or "") then return path end
    end

    return nil
end

local function saveItem(item)
    if not item then return end
    local base = desktopPath()
    local path

    if item.kind == "image" and item.image then
        path = uniquePath(base .. "/" .. sanitizeFilename(item.title) .. " " .. timestamp() .. ".png")
        if item.image:saveToFile(path, true, "PNG") then
            actionStatus("Saved image to Desktop.")
        else
            actionStatus("Could not save image.")
        end
    elseif item.kind == "file" and #item.files > 0 then
        local folder = uniquePath(base .. "/Clipboard Files " .. timestamp())
        hs.fs.mkdir(folder)
        local args = { "-R" }
        for _, file in ipairs(item.files) do table.insert(args, file) end
        table.insert(args, folder)
        if startTask("/bin/cp", args) then
            actionStatus("Copying files to Desktop.")
        else
            actionStatus("Could not start file copy.")
        end
    elseif item.kind == "url" then
        path = uniquePath(base .. "/" .. sanitizeFilename(item.title) .. ".url")
        if writeFile(path, item.text or item.urls[1] or "") then
            actionStatus("Saved URL to Desktop.")
        else
            actionStatus("Could not save URL.")
        end
    elseif item.kind == "markdown" then
        path = uniquePath(base .. "/" .. sanitizeFilename(item.title) .. ".md")
        if writeFile(path, item.text or "") then
            actionStatus("Saved Markdown to Desktop.")
        else
            actionStatus("Could not save Markdown.")
        end
    elseif item.kind == "richtext" and item.data and item.data["public.rtf"] then
        path = uniquePath(base .. "/" .. sanitizeFilename(item.title) .. ".rtf")
        if writeFile(path, item.data["public.rtf"]) then
            actionStatus("Saved rich text to Desktop.")
        else
            actionStatus("Could not save rich text.")
        end
    elseif item.kind == "richtext" and item.data and item.data["public.html"] then
        path = uniquePath(base .. "/" .. sanitizeFilename(item.title) .. ".html")
        if writeFile(path, item.data["public.html"]) then
            actionStatus("Saved HTML to Desktop.")
        else
            actionStatus("Could not save HTML.")
        end
    else
        path = uniquePath(base .. "/" .. sanitizeFilename(item.title) .. ".txt")
        if writeFile(path, item.text or item.title or "") then
            actionStatus("Saved text to Desktop.")
        else
            actionStatus("Could not save text.")
        end
    end
end

local function quickLookItem(item)
    -- Toggle: a second press closes the panel qlmanage already put on screen.
    if _G.clipboardMgrQLTask and _G.clipboardMgrQLTask:isRunning() then
        _G.clipboardMgrQLTask:terminate()
        _G.clipboardMgrQLTask = nil
        actionStatus("Closed Quick Look.")
        return
    end

    if not item then return end
    local files = item.kind == "file" and item.files or nil
    if not files or #files == 0 then
        local temp = writeItemToTemporaryFile(item)
        files = temp and { temp } or {}
    end

    if #files == 0 then
        actionStatus("Nothing to Quick Look.")
        return
    end

    local args = { "-p" }
    for _, file in ipairs(files) do table.insert(args, file) end
    local t = task.new("/usr/bin/qlmanage", nil, nil, args)
    if t and t:start() then
        _G.clipboardMgrQLTask = t
        actionStatus("Opened Quick Look.")
    else
        actionStatus("Could not start Quick Look.")
    end
end

local function openItem(item)
    if not item then return end
    if item.kind == "file" and item.files[1] then
        startTask("/usr/bin/open", item.files)
        actionStatus("Opened file.")
    elseif item.kind == "url" and (item.urls[1] or item.text) then
        hs.urlevent.openURL(item.urls[1] or item.text)
        actionStatus("Opened URL.")
    else
        actionStatus("Open is available for files and URLs.")
    end
end

local function revealItem(item)
    if not item or item.kind ~= "file" or not item.files[1] then
        actionStatus("Reveal is available for files.")
        return
    end
    startTask("/usr/bin/open", { "-R", item.files[1] })
    actionStatus("Revealed in Finder.")
end

local function deleteSelected()
    local idx = selectedHistoryIndex()
    if not idx then return end
    table.remove(history, idx)
    saveHistory()
    actionStatus("Deleted entry.")
end

local function clearHistory()
    for i = #history, 1, -1 do table.remove(history, i) end
    selected = 1
    query = ""
    saveHistory()
    actionStatus("Cleared clipboard history.")
end

local function actionRows()
    local rows = {
        { "Return", "Paste item and close" },
        { "Cmd+Return", "Paste item, keep window open" },
        { "Hold Cmd", "Show paste-by-number badges" },
        { "Cmd+1…9", "Paste numbered item, keep open" },
        { "Cmd+C", "Copy item to clipboard" },
        { "Space", "Show or hide preview" },
        { "Cmd+S", "Save item to Desktop" },
        { "Cmd+Y", "Quick Look item" },
        { "Cmd+O", "Open file or URL" },
        { "Cmd+R", "Reveal file in Finder" },
        { "Cmd+Delete", "Delete selected entry" },
        { "Cmd+Shift+Delete", "Clear all entries" },
        { "Up/Down", "Move selection" },
        { "Type", "Filter history" },
        { "Delete", "Edit filter text" },
        { "/ or ?", "Show actions" },
        { "Esc or Hyper+V", "Close window" },
    }

    local html = {}
    for _, row in ipairs(rows) do
        html[#html + 1] = string.format(
            '<div class="action-row"><kbd>%s</kbd><span>%s</span></div>',
            htmlEscape(row[1]),
            htmlEscape(row[2])
        )
    end
    return table.concat(html, "\n")
end

local function typeBadge(kind)
    local labels = {
        text = "Text",
        richtext = "Rich",
        markdown = "MD",
        image = "Image",
        file = "File",
        url = "URL",
    }
    return labels[kind] or "Item"
end

local function previewHTML(item)
    if not item then
        return '<div class="empty-detail">No item selected.</div>'
    end

    if item.kind == "image" and item.imageURL then
        return '<div class="image-preview"><img src="' .. cssEscape(item.imageURL) .. '" /></div>'
    end

    if item.kind == "file" then
        local paths = {}
        for _, file in ipairs(item.files or {}) do
            paths[#paths + 1] = htmlEscape(file)
        end
        return '<pre class="preview-body">' .. table.concat(paths, "\n") .. '</pre>'
    end

    local text = item.text or item.title or ""
    if item.kind == "richtext" and (not text or text == "") then
        text = "Rich text item with " .. tostring(#(item.types or {})) .. " pasteboard types."
    end
    return '<pre class="preview-body">' .. htmlEscape(text) .. '</pre>'
end

local function renderStatus()
    if statusText == "" then return "" end
    return '<div class="status-inline">' .. htmlEscape(statusText) .. '</div>'
end

local function renderDetail(item)
    if not detailMode then return "" end

    if detailMode == "preview" then
        return string.format(
            '<section class="detail"><div class="detail-title">%s</div>%s</section>',
            htmlEscape(item and item.title or "Preview"),
            previewHTML(item)
        )
    end

    local status = statusText ~= "" and '<div class="status">' .. htmlEscape(statusText) .. '</div>' or ""
    return '<section class="detail"><div class="detail-title">Actions</div>' .. status .. '<div class="actions">' .. actionRows() .. '</div></section>'
end

local function dragPayload(item)
    if not item then return "" end
    if item.kind == "file" and item.files[1] then return item.urls[1] or pathToFileURL(item.files[1]) end
    -- Finder turns dragged data:image URLs into text files, so image drags must
    -- advertise the cached PNG file that was created when the item was captured.
    if item.kind == "image" and item.imageFile then return pathToFileURL(item.imageFile) end
    if item.kind == "url" then return item.urls[1] or item.text or "" end
    return item.text or item.title or ""
end

local function renderHTML()
    updateFiltered()

    local item = selectedItem()
    local rows = {}
    local firstRow = 1
    if #filtered > VISIBLE_ROWS then
        firstRow = math.max(1, math.min(selected - 3, #filtered - VISIBLE_ROWS + 1))
    end
    local lastRow = math.min(#filtered, firstRow + VISIBLE_ROWS - 1)
    visibleFirst = firstRow

    for rowIndex = firstRow, lastRow do
        local historyIndex = filtered[rowIndex]
        local entry = history[historyIndex]
        local class = rowIndex == selected and "row selected" or "row"
        local num = rowIndex - firstRow + 1
        local numHTML = (cmdHeld and num <= 9) and ('<span class="num">' .. num .. '</span>') or ""
        rows[#rows + 1] = string.format(
            '<div class="%s" draggable="true" data-index="%d" data-drag="%s"><div class="row-top">%s<span class="row-title">%s</span><span class="badge">%s</span></div><div class="row-meta">%s</div></div>',
            class,
            rowIndex,
            htmlEscape(dragPayload(entry)),
            numHTML,
            htmlEscape(entry.title),
            htmlEscape(typeBadge(entry.kind)),
            htmlEscape(clip(entry.subtitle, 120))
        )
    end

    if #rows == 0 then
        rows[#rows + 1] = '<div class="empty">No clipboard items</div>'
    end

    local queryText = query ~= "" and htmlEscape(query) or "Clipboard history"
    local countText = #filtered > 0 and tostring(selected) .. " of " .. tostring(#filtered) or "0 items"
    local hasDetailClass = detailMode == "preview" and " has-detail" or ""
    local detailWidth = detailMode == "preview" and "360px 1fr" or "1fr"

    local mainHTML
    if detailMode == "help" then
        mainHTML = [[
  <main class="panel help-panel">
    <div class="query"><span class="query-title">Keyboard controls</span><span class="query-count">esc to close</span></div>
    <div class="help-scroll"><div class="actions">]] .. actionRows() .. [[</div></div>
  </main>]]
    else
        mainHTML = [[
  <main class="panel]] .. hasDetailClass .. [[">
    <section class="sidebar">
      <div class="query"><span class="query-title">]] .. queryText .. [[</span><span class="query-count">]] .. countText .. [[</span></div>
      ]] .. renderStatus() .. [[
      <div class="rows">]] .. table.concat(rows, "\n") .. [[</div>
    </section>
    ]] .. renderDetail(item) .. [[
  </main>]]
    end

    return [[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
:root {
  color-scheme: light dark;
  --bg: rgba(246, 246, 246, 0.94);
  --sidebar: rgba(234, 234, 236, 0.82);
  --line: rgba(0, 0, 0, 0.12);
  --text: #1d1d1f;
  --muted: rgba(60, 60, 67, 0.68);
  --selected: #007aff;
  --selected-muted: rgba(255, 255, 255, 0.78);
  --surface: rgba(255, 255, 255, 0.48);
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: rgba(32, 32, 34, 0.94);
    --sidebar: rgba(45, 45, 48, 0.82);
    --line: rgba(255, 255, 255, 0.12);
    --text: #f5f5f7;
    --muted: rgba(235, 235, 245, 0.62);
    --selected: #0a84ff;
    --selected-muted: rgba(255, 255, 255, 0.78);
    --surface: rgba(255, 255, 255, 0.08);
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
  grid-template-columns: ]] .. detailWidth .. [[;
  height: 100vh;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 18px;
  background: var(--bg);
  color: var(--text);
  box-shadow: 0 24px 80px rgba(0, 0, 0, 0.28);
  backdrop-filter: saturate(180%) blur(28px);
}

.sidebar {
  min-width: 0;
  overflow: hidden;
  border-right: 0;
  background: var(--sidebar);
}

.has-detail .sidebar {
  border-right: 1px solid var(--line);
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
  cursor: move;
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

.status-inline {
  margin: 8px 8px 0;
  padding: 8px 10px;
  border-radius: 8px;
  background: var(--surface);
  color: var(--muted);
  font-size: 12px;
}

.row {
  box-sizing: border-box;
  height: 62px;
  padding: 9px 11px;
  border-radius: 9px;
  overflow: hidden;
  transition: background-color 120ms ease, color 120ms ease, transform 120ms ease;
  cursor: grab;
}

.row:active {
  cursor: grabbing;
}

.row + .row {
  margin-top: 2px;
}

.row-top {
  display: flex;
  align-items: center;
  gap: 8px;
}

.row-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
  font-weight: 500;
  line-height: 18px;
}

.badge {
  flex: 0 0 auto;
  padding: 2px 6px;
  border-radius: 6px;
  background: var(--surface);
  color: var(--muted);
  font-size: 10px;
  font-weight: 600;
}

.row-meta {
  margin-top: 4px;
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
  transform: translateX(1px);
}

.selected .row-meta,
.selected .badge {
  color: var(--selected-muted);
}

.empty,
.empty-detail {
  padding: 18px 11px;
  color: var(--muted);
  font-size: 13px;
}

.detail {
  box-sizing: border-box;
  min-width: 0;
  padding: 24px 28px 28px;
  overflow: hidden;
}

.detail-title {
  margin-bottom: 16px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--muted);
  font-size: 13px;
  font-weight: 600;
}

.status {
  margin-bottom: 14px;
  padding: 8px 10px;
  border-radius: 8px;
  background: var(--surface);
  color: var(--text);
  font-size: 12px;
}

.actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px 12px;
}

.action-row {
  display: grid;
  grid-template-columns: 116px 1fr;
  align-items: center;
  min-height: 28px;
  gap: 10px;
  color: var(--muted);
  font-size: 12px;
}

kbd {
  display: inline-block;
  box-sizing: border-box;
  min-width: 32px;
  padding: 3px 7px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  font-size: 11px;
  font-weight: 600;
  text-align: center;
}

.preview-body {
  box-sizing: border-box;
  height: calc(100vh - 78px);
  margin: 0;
  overflow: auto;
  color: var(--text);
  font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
  font-size: 13px;
  line-height: 1.55;
  white-space: pre-wrap;
  word-break: break-word;
  -webkit-user-select: text;
}

.image-preview {
  display: flex;
  align-items: center;
  justify-content: center;
  height: calc(100vh - 78px);
  overflow: hidden;
  border-radius: 10px;
  background: var(--surface);
}

.image-preview img {
  display: block;
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

.row:hover:not(.selected) {
  background: var(--surface);
}

.num {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 18px;
  height: 18px;
  border-radius: 5px;
  background: var(--surface);
  color: var(--muted);
  font-size: 11px;
  font-weight: 700;
}

.selected .num {
  background: rgba(255, 255, 255, 0.25);
  color: #fff;
}

.help-scroll {
  box-sizing: border-box;
  height: calc(100% - 58px);
  padding: 20px 24px;
  overflow: auto;
}
</style>
</head>
<body>]] .. mainHTML .. [[
  <script>
    document.querySelectorAll('.row').forEach(function(row) {
      row.addEventListener('dragstart', function(event) {
        var value = row.getAttribute('data-drag') || '';
        event.dataTransfer.effectAllowed = 'copy';
        event.dataTransfer.setData('text/plain', value);
        if (/^https?:\/\//.test(value) || /^file:\/\//.test(value)) {
          event.dataTransfer.setData('text/uri-list', value);
        }
      });
      row.addEventListener('click', function() {
        try {
          window.webkit.messageHandlers.clipboardMgr.postMessage({
            type: 'click',
            index: parseInt(row.getAttribute('data-index'), 10)
          });
        } catch (e) {}
      });
    });
  </script>
</body>
</html>
]]
end

local function panelFrame()
    local f = hs.screen.mainScreen():frame()
    local targetW = detailMode and DETAIL_W or PANEL_W
    local w = math.min(targetW, f.w - 64)
    local h = math.min(PANEL_H, f.h - 64)
    local current = panelFrameCache
    local x = current and current.x or math.floor(f.x + (f.w - w) / 2)
    local y = current and current.y or math.floor(f.y + (f.h - h) / 2)
    return {
        x = x,
        y = y,
        w = math.floor(w),
        h = math.floor(h),
    }
end

function renderPanel()
    if not _G.clipboardMgrWebview then return end
    if panelVisible then
        panelFrameCache = panelFrame()
        _G.clipboardMgrWebview:frame(panelFrameCache)
    end
    _G.clipboardMgrWebview:html(renderHTML())
end

local function hidePanel()
    panelVisible = false
    draggingPanel = false
    panelHasInput = false
    cmdHeld = false
    if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
    if _G.clipboardMgrMouseTap then _G.clipboardMgrMouseTap:stop() end
    if _G.clipboardMgrWebview then
        _G.clipboardMgrWebview:delete(false, 0.08)
        _G.clipboardMgrWebview = nil
    end
end

local function moveSelection(delta)
    updateFiltered()
    if #filtered == 0 then return end
    selected = math.max(1, math.min(#filtered, selected + delta))
    statusText = ""
    renderPanel()
end

-- First click on a row selects it; clicking the already-selected row pastes and
-- closes (matches Finder-style single/double intent for a keyboardless panel).
local function handleRowClick(rowIndex)
    rowIndex = rowIndex and math.floor(rowIndex) or nil
    updateFiltered()
    if not rowIndex or not filtered[rowIndex] then return end
    if rowIndex == selected then
        pasteItem(history[filtered[rowIndex]], false)
    else
        selected = rowIndex
        statusText = ""
        renderPanel()
    end
end

local function onWebMessage(message)
    guarded("row click", function()
        local body = message and message.body
        if type(body) == "table" and body.type == "click" then
            handleRowClick(tonumber(body.index))
        end
    end)
end

local function buildPanel()
    if _G.clipboardMgrWebview then return end

    local controller = webview.usercontent.new("clipboardMgr")
    controller:setCallback(onWebMessage)

    _G.clipboardMgrWebview = webview.new(panelFrame(), {}, controller)
        :windowStyle(0)
        :allowTextEntry(false)
        :allowNewWindows(false)
        :transparent(true)
        :shadow(true)
        :level(hs.drawing.windowLevels.floating)
        :windowTitle("Clipboard History")
        :deleteOnClose(false)
        :closeOnEscape(false)
        :windowCallback(function(action)
            if action == "closing" then
                panelVisible = false
                if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:stop() end
            end
        end)
end

local function showPanel()
    if panelVisible and _G.clipboardMgrWebview and _G.clipboardMgrWebview:isVisible() then
        hidePanel()
        return
    end

    previousWindow = hs.window.frontmostWindow()
    query = ""
    selected = 1
    detailMode = nil
    statusText = ""
    panelFrameCache = nil
    panelHasInput = true
    cmdHeld = false
    buildPanel()
    panelFrameCache = panelFrame()
    _G.clipboardMgrWebview:frame(panelFrameCache)
    renderPanel()
    _G.clipboardMgrWebview:show(0.08):bringToFront(false)
    panelVisible = true
    if _G.clipboardMgrKeyTap then _G.clipboardMgrKeyTap:start() end
    if _G.clipboardMgrMouseTap then _G.clipboardMgrMouseTap:start() end
end

local lastChange = pb.changeCount()

_G.clipboardMgrTimer = hs.timer.doEvery(POLL, function()
    guarded("capture", function()
        local c = pb.changeCount()
        if c == lastChange then return end
        lastChange = c

        pushEntry(makeEntryFromPasteboard())
        if panelVisible then renderPanel() end
    end)
end):start()

_G.clipboardMgrKeyTap = eventtap.new({ eventtap.event.types.keyDown, eventtap.event.types.flagsChanged }, function(e)
    return guarded("key handler", function()
        if not panelVisible then return false end

        -- Holding Cmd overlays paste-by-number badges. Observe the modifier
        -- without consuming it so Cmd-shortcuts still reach their keyDown.
        if e:getType() == eventtap.event.types.flagsChanged then
            local held = e:getFlags().cmd == true
            if held ~= cmdHeld then
                cmdHeld = held
                renderPanel()
            end
            return false
        end

        local key = keycodes.map[e:getKeyCode()]
        local flags = e:getFlags()
        local hasCommand = flags.cmd or flags.ctrl or flags.alt
        local item = selectedItem()

        if key == "v" and hasHyper(flags) then
            hidePanel()
            return true
        end

        -- Esc closes from anywhere, even after focus has moved to another app.
        if key == "escape" then
            hidePanel()
            return true
        end

        -- The panel intentionally floats while users work elsewhere. Once a
        -- click lands outside it, shortcuts like Cmd+C must pass through so new
        -- clipboard items can still be captured while the manager is visible.
        if not panelHasInput then return false end

        if key == "down" then
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
            statusText = ""
            renderPanel()
            return true
        elseif key == "end" then
            updateFiltered()
            selected = math.max(1, #filtered)
            statusText = ""
            renderPanel()
            return true
        elseif key == "return" and flags.cmd then
            pasteItem(item, true)
            renderPanel()
            return true
        elseif key == "return" then
            pasteItem(item, false)
            return true
        elseif flags.cmd and key and key:match("^[1-9]$") then
            local target = visibleFirst + tonumber(key) - 1
            updateFiltered()
            if filtered[target] then
                selected = target
                pasteItem(history[filtered[target]], true)
                renderPanel()
            end
            return true
        elseif key == "space" then
            -- `x and nil or y` always yields y in Lua, so toggle with the
            -- truthy value first to actually hide on the second press.
            detailMode = (detailMode ~= "preview") and "preview" or nil
            statusText = ""
            renderPanel()
            return true
        elseif key == "c" and flags.cmd then
            copyItem(item)
            renderPanel()
            return true
        elseif key == "s" and flags.cmd then
            saveItem(item)
            renderPanel()
            return true
        elseif key == "y" and flags.cmd then
            quickLookItem(item)
            renderPanel()
            return true
        elseif key == "o" and flags.cmd then
            openItem(item)
            renderPanel()
            return true
        elseif key == "r" and flags.cmd then
            revealItem(item)
            renderPanel()
            return true
        elseif key == "delete" and flags.cmd and flags.shift then
            clearHistory()
            renderPanel()
            return true
        elseif key == "delete" and flags.cmd then
            deleteSelected()
            renderPanel()
            return true
        elseif key == "delete" then
            query = dropLastChar(query)
            selected = 1
            statusText = ""
            renderPanel()
            return true
        end

        if not hasCommand then
            local ch = e:getCharacters(true)
            if ch == "?" or ch == "/" then
                detailMode = (detailMode ~= "help") and "help" or nil
                statusText = ""
                renderPanel()
                return true
            elseif ch and ch ~= "" and ch:match("%C") then
                query = query .. ch
                selected = 1
                statusText = ""
                renderPanel()
                return true
            end
        end

        return true
    end, true)
end)

local function isPointInFrame(point, frame)
    return point.x >= frame.x and point.x <= frame.x + frame.w
        and point.y >= frame.y and point.y <= frame.y + frame.h
end

local function isInDragHandle(point, frame)
    return isPointInFrame(point, frame)
        and point.y >= frame.y
        and point.y <= frame.y + QUERY_H + 8
end

_G.clipboardMgrMouseTap = eventtap.new({
    eventtap.event.types.leftMouseDown,
    eventtap.event.types.leftMouseDragged,
    eventtap.event.types.leftMouseUp,
}, function(e)
    if not panelVisible or not _G.clipboardMgrWebview then return false end

    local point = e:location()
    local frame = panelFrameCache or _G.clipboardMgrWebview:frame()
    local flags = e:getFlags()
    local eventType = e:getType()

    if eventType == eventtap.event.types.leftMouseDown then
        if not isPointInFrame(point, frame) then
            panelHasInput = false
            return false
        end

        panelHasInput = true
        if flags.cmd or isInDragHandle(point, frame) then
            draggingPanel = true
            dragStartMouse = point
            dragStartFrame = frame
            return true
        end

        -- Row drags need to remain native WebKit drags so users can drop items
        -- into Finder/apps without removing them from clipboard history.
        return false
    elseif eventType == eventtap.event.types.leftMouseDragged then
        if draggingPanel and dragStartMouse and dragStartFrame then
            panelFrameCache = {
                x = math.floor(dragStartFrame.x + point.x - dragStartMouse.x),
                y = math.floor(dragStartFrame.y + point.y - dragStartMouse.y),
                w = dragStartFrame.w,
                h = dragStartFrame.h,
            }
            _G.clipboardMgrWebview:frame(panelFrameCache)
            return true
        end
        return false
    elseif eventType == eventtap.event.types.leftMouseUp then
        if draggingPanel then
            draggingPanel = false
            dragStartMouse = nil
            dragStartFrame = nil
            return true
        end
    end

    return false
end)

_G.clipboardMgrHotkey = hs.hotkey.bind(HYPER, "v", showPanel)
_G.clipboardMgrShow = showPanel
