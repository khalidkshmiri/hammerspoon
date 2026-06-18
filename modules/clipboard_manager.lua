package.loaded["modules.clipboard_manager"] = nil

-- ── Clipboard history manager ─────────────────────────────────────────────────
-- Hyper+V opens a dark, translucent, keyboard-driven panel of the last 100 clips.
-- Captures plain text, rich text, images, files/paths and URLs; picking one
-- re-pastes it into whatever app was front. History persists across reboots:
-- metadata + text in a JSON file, image PNGs and rich-text snapshots as blobs on
-- disk (CACHE_DIR). Oldest entries (and their blobs) are evicted past MAX_ITEMS.
--
-- Replaces the old clipboard_ring (text-only, hs.chooser). Reuses its capture
-- shape: poll changeCount, dedup-to-top, skip nspasteboard transient/concealed
-- scratch writes.
--
-- Cooperation with paste_manager: paste_manager intercepts EVERY Cmd+V and strips
-- rich formatting when the clipboard holds rich UTIs. That would mangle our rich
-- re-paste, so we post our paste tagged with paste_manager's MAGIC sentinel, which
-- its eventtap ignores — our paste lands exactly as we staged it. For text/rich we
-- also tag the clipboard write transient/concealed so our own poll (and other
-- history managers) never re-record it; image/file writes can't carry those
-- markers, so a one-shot ignore guard skips the single change they cause.

-- Reload safety: tear down everything the previous load created.
if _G.clipboardMgrTimer    then _G.clipboardMgrTimer:stop()     end
if _G.clipboardMgrWebview  then _G.clipboardMgrWebview:delete()  end
if _G.clipboardMgrHotkey   then _G.clipboardMgrHotkey:delete()   end

local pb       = hs.pasteboard
local eventtap = hs.eventtap
local props    = eventtap.event.properties

local MAX_ITEMS = 100
local POLL      = 0.5  -- seconds between change-count checks (no native pasteboard callback)
local HYPER     = { "cmd", "ctrl", "alt", "shift" }

-- Must match paste_manager's MAGIC so its Cmd+V tap passes our synthetic paste
-- through untouched (no rich-text stripping). Keep these two in sync.
local MAGIC = 0x504C4149 -- "PLAI"

-- nspasteboard.org markers: a clip carrying either is a clipboard-manager's own
-- scratch write — never record it.
local CONCEALED = "org.nspasteboard.ConcealedType"
local TRANSIENT = "org.nspasteboard.TransientType"
local SKIP_UTIS = { [CONCEALED] = true, [TRANSIENT] = true }

local RICH_UTIS = {
    ["public.rtf"] = true, ["public.html"] = true, ["com.apple.webarchive"] = true,
    ["public.rtfd"] = true, ["com.apple.flat-rtfd"] = true,
}
local PLAIN_UTI = "public.utf8-plain-text"
local FILE_UTI  = "public.file-url"

local CACHE_DIR = hs.configdir .. "/clipboard-cache"
local JSON_PATH = CACHE_DIR .. "/history.json"
hs.fs.mkdir(CACHE_DIR) -- no-op if it already exists

-- ── In-memory model ───────────────────────────────────────────────────────────
-- Persist the live list across config reloads so a save doesn't drop history.
-- Item: { id, kind="text|rich|image|file|url", preview, ts,
--         text,                       text/url/rich plain-derivation
--         richFile="rich-<id>.json",  base64-per-UTI snapshot (rich)
--         imageFile="img-<id>.png",   cached PNG (image)
--         thumb,                      data-URL, built lazily on show, NOT persisted
--         paths={...} }               file kind
_G.clipboardMgrHistory = _G.clipboardMgrHistory or { items = {}, nextId = 1 }
local state   = _G.clipboardMgrHistory
local history = state.items

local function allocId()
    local id = state.nextId
    state.nextId = state.nextId + 1
    return id
end

-- ── Persistence ───────────────────────────────────────────────────────────────
local function blobPath(name) return CACHE_DIR .. "/" .. name end

local function saveHistory()
    local meta = {}
    for _, it in ipairs(history) do
        meta[#meta + 1] = {
            id = it.id, kind = it.kind, preview = it.preview, text = it.text,
            imageFile = it.imageFile, richFile = it.richFile,
            paths = it.paths, urls = it.urls, ts = it.ts,
        }
    end
    hs.json.write({ nextId = state.nextId, items = meta }, JSON_PATH, true, true)
end

local function saveRichSnapshot(id, snap)
    local enc = {}
    for uti, raw in pairs(snap) do enc[uti] = hs.base64.encode(raw) end
    local name = "rich-" .. id .. ".json"
    hs.json.write(enc, blobPath(name), false, true)
    return name
end

local function loadRichSnapshot(item)
    local enc = hs.json.read(blobPath(item.richFile))
    local snap = {}
    for uti, b64 in pairs(enc or {}) do snap[uti] = hs.base64.decode(b64) end
    return snap
end

-- Delete the on-disk blobs an evicted/replaced item owned, so the cache doesn't grow.
local function removeBlobs(item)
    if item.imageFile then os.remove(blobPath(item.imageFile)) end
    if item.richFile  then os.remove(blobPath(item.richFile))  end
end

-- Rebuild the list from disk on the very first load; drop entries whose blobs vanished.
if not state.loaded then
    local data = hs.fs.attributes(JSON_PATH) and hs.json.read(JSON_PATH)
    if data then
        state.nextId = data.nextId or 1
        for _, it in ipairs(data.items or {}) do
            local ok = true
            if it.imageFile and not hs.fs.attributes(blobPath(it.imageFile)) then ok = false end
            if it.richFile  and not hs.fs.attributes(blobPath(it.richFile))  then ok = false end
            if ok then history[#history + 1] = it end
        end
    end
    state.loaded = true
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- Collapse whitespace so multi-line clips read as one preview row.
local function oneLine(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, n)
    if #s > n then return s:sub(1, n) .. "…" end
    return s
end

local function basename(p) return p:match("([^/]+)/?$") or p end

-- ── Capture & classify ────────────────────────────────────────────────────────
local function shouldSkip()
    for _, uti in ipairs(pb.contentTypes() or {}) do
        if SKIP_UTIS[uti] then return true end
    end
    return false
end

-- Whole-string single URL (so a sentence merely containing a link stays "text").
local URL_PAT = "^%s*%a[%w+.%-]*://[^%s]+%s*$"

local function classify()
    local utis = pb.contentTypes() or {}
    local has  = {}
    for _, u in ipairs(utis) do has[u] = true end

    -- 1) IMAGE
    local img = pb.readImage()
    if img then
        local id   = allocId()
        local name = "img-" .. id .. ".png"
        img:saveToFile(blobPath(name))
        local sz = img:size()
        return {
            id = id, kind = "image", imageFile = name,
            thumb = img:encodeAsURLString("png"),
            preview = string.format("Image  %d×%d", math.floor(sz.w), math.floor(sz.h)),
        }
    end

    -- 2) FILE(S) — readURL(nil,true) returns an array of NSURL tables, each with a
    -- pre-decoded .filePath (for display) and a correctly-encoded .url (for re-paste).
    if has[FILE_UTI] then
        local nsurls = pb.readURL(nil, true)
        local paths, urls = {}, {}
        if type(nsurls) == "table" then
            for _, u in ipairs(nsurls) do
                if type(u) == "table" and u.filePath then
                    paths[#paths + 1] = u.filePath
                    urls[#urls + 1]  = u.url
                end
            end
        end
        if #paths > 0 then
            local names = {}
            for _, p in ipairs(paths) do names[#names + 1] = basename(p) end
            return {
                id = allocId(), kind = "file", paths = paths, urls = urls,
                preview = (#paths == 1) and names[1]
                    or (#paths .. " files: " .. table.concat(names, ", ")),
            }
        end
    end

    -- 3) RICH — snapshot every representation for an exact re-paste.
    for u in pairs(RICH_UTIS) do
        if has[u] then
            local id    = allocId()
            local snap  = pb.readAllData()
            local plain = pb.readString() or "(rich text)"
            return {
                id = id, kind = "rich", text = plain,
                richFile = saveRichSnapshot(id, snap),
                preview  = oneLine(plain),
            }
        end
    end

    -- 4 & 5) URL vs PLAIN
    local s = pb.readString()
    if not s or s == "" then return nil end
    if s:match(URL_PAT) then
        return { id = allocId(), kind = "url", text = s, preview = oneLine(s) }
    end
    return { id = allocId(), kind = "text", text = s, preview = oneLine(s) }
end

local function sameItem(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "text" or a.kind == "url" or a.kind == "rich" then
        return a.text == b.text
    elseif a.kind == "file" then
        return table.concat(a.paths or {}, "\n") == table.concat(b.paths or {}, "\n")
    end
    return false -- images: never dedup (byte-compare too costly; repeats are rare)
end

local function pushItem(item)
    item.ts = os.time()
    -- Move an existing identical clip to the top; reclaim its blobs (item supersedes).
    for i, v in ipairs(history) do
        if sameItem(v, item) then removeBlobs(v); table.remove(history, i); break end
    end
    table.insert(history, 1, item)
    while #history > MAX_ITEMS do removeBlobs(history[#history]); table.remove(history) end
    saveHistory()
end

local lastChange = pb.changeCount()

_G.clipboardMgrTimer = hs.timer.doEvery(POLL, function()
    local c = pb.changeCount()
    if c == lastChange then return end
    lastChange = c
    -- One-shot guard: our own image/file re-paste write (untagged) lands here once.
    if _G.clipboardMgrIgnore then _G.clipboardMgrIgnore = false; return end
    if shouldSkip() then return end
    local item = classify()
    if item then pushItem(item) end
end):start()

-- ── Re-paste ──────────────────────────────────────────────────────────────────
-- Tagged with MAGIC so paste_manager's tap passes it straight through (no strip).
local function postPaste()
    local down = eventtap.event.newKeyEvent({ "cmd" }, "v", true)
    local up   = eventtap.event.newKeyEvent({ "cmd" }, "v", false)
    down:setProperty(props.eventSourceUserData, MAGIC)
    up:setProperty(props.eventSourceUserData, MAGIC)
    down:post()
    up:post()
end

local function findById(id)
    for _, it in ipairs(history) do if it.id == id then return it end end
end

local function repaste(item)
    if item.kind == "text" or item.kind == "url" then
        pb.writeAllData({ [PLAIN_UTI] = item.text, [CONCEALED] = "", [TRANSIENT] = "" })

    elseif item.kind == "rich" then
        local snap = loadRichSnapshot(item)
        snap[CONCEALED] = ""
        snap[TRANSIENT] = ""
        pb.writeAllData(snap)

    elseif item.kind == "image" then
        local img = hs.image.imageFromPath(blobPath(item.imageFile))
        if not img then return end
        _G.clipboardMgrIgnore = true -- writeObjects can't carry the skip markers
        pb.writeObjects(img)

    elseif item.kind == "file" then
        local objs = {}
        for _, u in ipairs(item.urls or {}) do objs[#objs + 1] = { url = u } end
        if #objs == 0 then return end
        _G.clipboardMgrIgnore = true
        pb.writeObjects(objs)
    end

    -- Re-activate the app that was front when the panel opened, then paste into it.
    local target = _G.clipboardMgrTargetApp
    if target then target:activate() end
    hs.timer.doAfter(0.08, postPaste)
end

-- ── Panel (hs.webview) ────────────────────────────────────────────────────────
-- usercontent bridges JS → Lua: the panel posts {action,id} when the user picks or
-- dismisses. Created once per load; torn down on the next reload via :delete() above.
local userContent = hs.webview.usercontent.new("clipMgr")
userContent:setCallback(function(msg)
    -- HS bindings have posted either the raw body or a {body=...} wrapper across
    -- versions — accept both.
    local m = (type(msg) == "table" and msg.body) and msg.body or msg
    if type(m) ~= "table" then return end
    if _G.clipboardMgrWebview then _G.clipboardMgrWebview:hide() end
    if m.action == "paste" then
        local item = findById(tonumber(m.id))
        if item then repaste(item) end
    end
end)

local screen = hs.screen.mainScreen():frame()
local W, H = 720, 480
local rect = {
    x = screen.x + (screen.w - W) / 2,
    y = screen.y + (screen.h - H) / 3,
    w = W, h = H,
}

_G.clipboardMgrWebview = hs.webview.new(rect, { developerExtrasEnabled = false }, userContent)
    :windowStyle({ "borderless" })
    :allowTextEntry(true)            -- required so the search <input> receives typing
    :transparent(true)              -- let the CSS rounded panel show through
    :level(hs.drawing.windowLevels.modalPanel)
    :closeOnEscape(true)
    :deleteOnClose(false)

-- HTML shell is rebuilt with the current rows each show, so the JS sees the data at
-- parse time (no async render() race). textContent (not innerHTML) is used for all
-- clip text, so a clip can never inject markup.
local function panelHTML(rowsJSON)
    return [[<!DOCTYPE html><html><head><meta charset="utf-8"><style>
* { margin:0; padding:0; box-sizing:border-box; }
html,body { background:transparent; }
body { font:13px -apple-system,system-ui,sans-serif; color:#fff; padding:18px;
       -webkit-user-select:none; cursor:default; }
#panel { background:rgba(30,30,32,0.86); -webkit-backdrop-filter:blur(24px);
         border:0.5px solid rgba(255,255,255,0.14); border-radius:13px;
         box-shadow:0 18px 50px rgba(0,0,0,0.55); overflow:hidden;
         height:calc(100vh - 36px); display:flex; flex-direction:column; }
#q { width:100%; border:none; outline:none; background:transparent; color:#fff;
     font-size:16px; padding:14px 18px; border-bottom:0.5px solid rgba(255,255,255,0.10); }
#q::placeholder { color:rgba(235,235,245,0.4); }
#list { flex:1; overflow-y:auto; padding:6px; }
#list::-webkit-scrollbar { width:0; }
.item { display:flex; align-items:center; gap:10px; padding:9px 12px;
        border-radius:8px; }
.item.sel { background:rgba(10,132,255,0.85); }
.badge { flex:0 0 auto; font-size:10px; font-weight:600; letter-spacing:0.3px;
         text-transform:uppercase; padding:2px 6px; border-radius:5px;
         background:rgba(255,255,255,0.14); color:rgba(255,255,255,0.85); }
.item.sel .badge { background:rgba(255,255,255,0.25); color:#fff; }
.txt { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.thumb { flex:0 0 auto; height:34px; max-width:90px; border-radius:4px;
         object-fit:cover; background:rgba(255,255,255,0.08); }
#empty { color:rgba(235,235,245,0.4); text-align:center; padding:40px; }
</style></head><body><div id="panel">
<input id="q" placeholder="Clipboard history" autofocus autocomplete="off">
<div id="list"></div></div>
<script>
const ITEMS = ]] .. rowsJSON .. [[;
const KIND = { text:"text", rich:"rich", image:"image", file:"file", url:"url" };
const q = document.getElementById('q'), listEl = document.getElementById('list');
let visible = [], sel = 0;

function draw() {
  listEl.innerHTML = '';
  if (visible.length === 0) {
    const e = document.createElement('div'); e.id='empty';
    e.textContent = ITEMS.length ? 'No matches' : 'No clipboard history yet';
    listEl.appendChild(e); return;
  }
  visible.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'item' + (i === sel ? ' sel' : '');
    const b = document.createElement('span'); b.className='badge';
    b.textContent = KIND[it.kind] || it.kind; row.appendChild(b);
    const t = document.createElement('span'); t.className='txt';
    t.textContent = it.preview; row.appendChild(t);
    if (it.thumb) { const im = document.createElement('img');
      im.className='thumb'; im.src = it.thumb; row.appendChild(im); }
    row.addEventListener('click', () => choose(it.id));
    listEl.appendChild(row);
  });
  const cur = listEl.children[sel];
  if (cur && cur.scrollIntoView) cur.scrollIntoView({ block:'nearest' });
}

function filter() {
  const term = q.value.toLowerCase();
  visible = ITEMS.filter(it => !term || it.preview.toLowerCase().includes(term));
  sel = 0; draw();
}

function post(o) { window.webkit.messageHandlers.clipMgr.postMessage(o); }
function choose(id) { post({ action:'paste', id:id }); }

document.addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { sel = Math.min(sel+1, visible.length-1); draw(); e.preventDefault(); }
  else if (e.key === 'ArrowUp') { sel = Math.max(sel-1, 0); draw(); e.preventDefault(); }
  else if (e.key === 'Enter') { if (visible[sel]) choose(visible[sel].id); e.preventDefault(); }
  else if (e.key === 'Escape') { post({ action:'close' }); e.preventDefault(); }
});
q.addEventListener('input', filter);
window.addEventListener('load', () => { q.focus(); filter(); });
filter();
</script></body></html>]]
end

-- Build the lightweight rows the panel needs (no heavy blobs except image thumbs,
-- which are rebuilt lazily and cached on the item so reloads stay cheap).
local function buildRows()
    local rows = {}
    for _, it in ipairs(history) do
        local thumb = it.thumb
        if it.kind == "image" and not thumb and it.imageFile then
            local img = hs.image.imageFromPath(blobPath(it.imageFile))
            if img then thumb = img:encodeAsURLString("png"); it.thumb = thumb end
        end
        rows[#rows + 1] = { id = it.id, kind = it.kind, preview = clip(it.preview, 200), thumb = thumb }
    end
    return rows
end

local function showPanel()
    _G.clipboardMgrTargetApp = hs.application.frontmostApplication()
    -- gsub guards against a clip's text closing the inline <script> early.
    local json = (hs.json.encode(buildRows()) or "[]"):gsub("</", "<\\/")
    _G.clipboardMgrWebview:html(panelHTML(json))
    _G.clipboardMgrWebview:show():bringToFront(true)
    -- autofocus is unreliable right after an html swap; nudge focus explicitly.
    hs.timer.doAfter(0.05, function()
        _G.clipboardMgrWebview:evaluateJavaScript("document.getElementById('q').focus()")
    end)
end

_G.clipboardMgrHotkey = hs.hotkey.bind(HYPER, "v", showPanel)

-- ── CLI exposure (hs -c) ──────────────────────────────────────────────────────
_G.clipboardMgrShow = showPanel
_G.clipboardMgrClear = function()
    for _, it in ipairs(history) do removeBlobs(it) end
    for i = #history, 1, -1 do table.remove(history, i) end -- empty in place; keep the upvalue
    saveHistory()
end
