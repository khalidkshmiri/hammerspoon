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
--
-- Keyboard model (why an eventtap, not the webview's own key handling): the panel
-- is a borderless hs.webview, and a borderless NSWindow can't become the key
-- window — so its <input> never gets keyboard focus until the user clicks it
-- (that was issue #11: Esc did nothing until you clicked first). Instead of
-- fighting NSWindow, we own the keyboard with a global hs.eventtap that's live
-- only while the panel is showing: it fires regardless of which window is key, so
-- Esc/arrows/actions work the instant the panel opens. Lua holds the search query
-- and selection; the webview is a pure renderer driven by setState() calls.

-- Reload safety: tear down everything the previous load created.
if _G.clipboardMgrTimer    then _G.clipboardMgrTimer:stop()     end
if _G.clipboardMgrTap      then _G.clipboardMgrTap:stop()        end
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

-- Shell-quote a single argument safely (paths may contain spaces/quotes).
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

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

local function findById(id)
    for _, it in ipairs(history) do if it.id == id then return it end end
end

-- ── Clipboard staging / re-paste ──────────────────────────────────────────────
-- Stage an item onto the system clipboard. `manual=true` writes a *real* clip the
-- user will paste themselves (no transient markers, no MAGIC) — issue #9's
-- copy-for-manual-paste. Otherwise it stages for our own synthetic paste, tagging
-- text/rich transient so our poll never re-records it.
local function stageClipboard(item, manual)
    if item.kind == "text" or item.kind == "url" then
        if manual then
            pb.setContents(item.text)
        else
            pb.writeAllData({ [PLAIN_UTI] = item.text, [CONCEALED] = "", [TRANSIENT] = "" })
        end

    elseif item.kind == "rich" then
        local snap = loadRichSnapshot(item)
        if not manual then snap[CONCEALED] = ""; snap[TRANSIENT] = "" end
        pb.writeAllData(snap)

    elseif item.kind == "image" then
        local img = hs.image.imageFromPath(blobPath(item.imageFile))
        if not img then return false end
        _G.clipboardMgrIgnore = true -- writeObjects can't carry the skip markers
        pb.writeObjects(img)

    elseif item.kind == "file" then
        local objs = {}
        for _, u in ipairs(item.urls or {}) do objs[#objs + 1] = { url = u } end
        if #objs == 0 then return false end
        _G.clipboardMgrIgnore = true
        pb.writeObjects(objs)
    end
    return true
end

-- Tagged with MAGIC so paste_manager's tap passes it straight through (no strip).
local function postPaste()
    local down = eventtap.event.newKeyEvent({ "cmd" }, "v", true)
    local up   = eventtap.event.newKeyEvent({ "cmd" }, "v", false)
    down:setProperty(props.eventSourceUserData, MAGIC)
    up:setProperty(props.eventSourceUserData, MAGIC)
    down:post()
    up:post()
end

-- Re-activate the app that was front when the panel opened, then paste into it.
local function repaste(item)
    if not stageClipboard(item, false) then return end
    local target = _G.clipboardMgrTargetApp
    if target then target:activate() end
    hs.timer.doAfter(0.08, postPaste)
end

-- ── Per-item side actions (issue #10) ─────────────────────────────────────────
local DESKTOP = (os.getenv("HOME") or "~") .. "/Desktop"

-- Backing file for Quick Look / reveal / save; for non-file kinds we materialise
-- the text to a scratch file so those actions still have something to point at.
local function backingPath(item)
    if item.kind == "image" then return blobPath(item.imageFile) end
    if item.kind == "file"  then return (item.paths or {})[1] end
    local p = blobPath("preview-" .. item.id .. ".txt")
    local fh = io.open(p, "w")
    if fh then fh:write(item.text or item.preview or ""); fh:close() end
    return p
end

local function quickLook(item)
    local p = backingPath(item)
    if p then hs.execute("qlmanage -p " .. shq(p) .. " >/dev/null 2>&1 &") end
end

local function revealInFinder(item)
    local p
    if item.kind == "file"  then p = (item.paths or {})[1] end
    if item.kind == "image" then p = blobPath(item.imageFile) end
    if p then hs.execute("open -R " .. shq(p))
    else hs.alert.show("No file to reveal", 0.8) end
end

local function saveToDesktop(item)
    if item.kind == "image" then
        hs.execute("cp " .. shq(blobPath(item.imageFile)) .. " " .. shq(DESKTOP .. "/clip-" .. item.id .. ".png"))
    elseif item.kind == "file" then
        for _, p in ipairs(item.paths or {}) do hs.execute("cp -R " .. shq(p) .. " " .. shq(DESKTOP) .. "/") end
    else
        local fh = io.open(DESKTOP .. "/clip-" .. item.id .. ".txt", "w")
        if fh then fh:write(item.text or item.preview or ""); fh:close() end
    end
    hs.alert.show("Saved to Desktop", 0.8)
end

-- macOS share sheet via NSSharingServicePicker (no CLI exists for this; AppleScript
-- pops the picker anchored to the frontmost app). Shares the backing file/URL.
local function shareItem(item)
    local p = (item.kind == "url") and item.text or backingPath(item)
    if not p then return end
    -- Best-effort: open the share sheet by routing through Finder for file-backed
    -- items; text/url fall back to copying for the user to share manually.
    if item.kind == "file" or item.kind == "image" then
        hs.execute("open -R " .. shq(p)) -- reveal, then user invokes Share from Finder
        hs.alert.show("Revealed — use Finder ▸ Share", 1.0)
    else
        pb.setContents(p)
        hs.alert.show("Copied — paste to share", 1.0)
    end
end

local function deleteItem(id)
    for i, v in ipairs(history) do
        if v.id == id then removeBlobs(v); table.remove(history, i); break end
    end
    saveHistory()
end

local function clearAll()
    for _, it in ipairs(history) do removeBlobs(it) end
    for i = #history, 1, -1 do table.remove(history, i) end -- empty in place; keep the upvalue
    saveHistory()
end

-- ── Panel (hs.webview) ────────────────────────────────────────────────────────
-- Lua owns the query + selection; the webview is a renderer driven by setState().
-- usercontent bridges JS → Lua only for mouse clicks (keyboard goes through the
-- eventtap below).
local panel = { rows = {}, visible = {}, sel = 1, query = "", help = false }

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

local function rowById(id)
    for _, r in ipairs(panel.rows) do if r.id == id then return r end end
end

-- Recompute the filtered id list and clamp the selection.
local function refilter()
    local q = panel.query:lower()
    panel.visible = {}
    for _, r in ipairs(panel.rows) do
        if q == "" or r.preview:lower():find(q, 1, true) then
            panel.visible[#panel.visible + 1] = r.id
        end
    end
    if panel.sel > #panel.visible then panel.sel = #panel.visible end
    if panel.sel < 1 then panel.sel = 1 end
end

-- JSON-encode a bare string (hs.json.encode only handles tables).
local function jsStr(s)
    return '"' .. s:gsub('[%c\\"]', function(c)
        local map = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n',
                      ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function pushState()
    if not _G.clipboardMgrWebview then return end
    -- An empty Lua table json-encodes as "{}" (object); force "[]" so JS sees an array.
    local ids = (#panel.visible > 0 and hs.json.encode(panel.visible)) or "[]"
    _G.clipboardMgrWebview:evaluateJavaScript(
        string.format("setState(%s,%d,%s,%s)", ids, panel.sel - 1, jsStr(panel.query), tostring(panel.help)))
end

-- Reload the renderer's full item map (after a structural change: delete/clear),
-- then push the filtered view.
local function reloadRows()
    panel.rows = buildRows()
    refilter()
    if _G.clipboardMgrWebview then
        local json = ((#panel.rows > 0 and hs.json.encode(panel.rows)) or "[]"):gsub("</", "<\\/")
        _G.clipboardMgrWebview:evaluateJavaScript("loadItems(" .. json .. ")")
    end
    pushState()
end

local function currentItem()
    local id = panel.visible[panel.sel]
    if id then return findById(id) end
end

-- ── HTML shell ────────────────────────────────────────────────────────────────
-- Rebuilt with the current rows each show so the JS sees data at parse time (no
-- async render race). textContent (not innerHTML) for all clip text, so a clip can
-- never inject markup.
local function panelHTML(rowsJSON)
    return [[<!DOCTYPE html><html><head><meta charset="utf-8"><style>
* { margin:0; padding:0; box-sizing:border-box; }
html,body { background:transparent; }
body { font:13px -apple-system,system-ui,sans-serif; color:#fff; padding:18px;
       -webkit-user-select:none; cursor:default; }
#panel { background:rgba(28,28,30,0.82); -webkit-backdrop-filter:blur(28px) saturate(180%);
         border:0.5px solid rgba(255,255,255,0.14); border-radius:13px;
         box-shadow:0 18px 60px rgba(0,0,0,0.6); overflow:hidden;
         height:calc(100vh - 36px); display:flex; flex-direction:column; position:relative; }
#q { display:flex; align-items:center; gap:8px; padding:13px 18px;
     border-bottom:0.5px solid rgba(255,255,255,0.10); font-size:16px; }
#q .icon { opacity:0.45; }
#q .text { flex:1; white-space:pre; overflow:hidden; text-overflow:ellipsis; }
#q .ph { color:rgba(235,235,245,0.4); }
#q .caret { width:1.5px; height:18px; background:rgba(10,132,255,0.95);
            display:inline-block; animation:blink 1.1s steps(1) infinite; }
@keyframes blink { 50% { opacity:0; } }
#list { flex:1; overflow-y:auto; padding:6px; }
#list::-webkit-scrollbar { width:0; }
.item { display:flex; align-items:center; gap:10px; padding:9px 12px;
        border-radius:8px; }
.item.sel { background:rgba(10,132,255,0.9); }
.num { flex:0 0 auto; width:15px; text-align:center; font:11px ui-monospace,monospace;
       color:rgba(235,235,245,0.4); }
.item.sel .num { color:rgba(255,255,255,0.85); }
.badge { flex:0 0 auto; font-size:10px; font-weight:700; letter-spacing:0.4px;
         text-transform:uppercase; padding:2px 6px; border-radius:5px;
         background:rgba(255,255,255,0.14); color:rgba(255,255,255,0.9); }
.badge.text  { background:rgba(142,142,147,0.30); }
.badge.url   { background:rgba(10,132,255,0.32); }
.badge.image { background:rgba(191,90,242,0.32); }
.badge.file  { background:rgba(50,215,75,0.30); }
.badge.rich  { background:rgba(255,159,10,0.32); }
.item.sel .badge { background:rgba(255,255,255,0.28); color:#fff; }
.txt { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.thumb { flex:0 0 auto; height:34px; max-width:90px; border-radius:4px;
         object-fit:cover; background:rgba(255,255,255,0.08); }
#empty { color:rgba(235,235,245,0.4); text-align:center; padding:40px; }
#foot { display:flex; gap:14px; padding:9px 16px; font-size:11px;
        color:rgba(235,235,245,0.55); border-top:0.5px solid rgba(255,255,255,0.10);
        white-space:nowrap; overflow:hidden; }
#foot b { color:rgba(255,255,255,0.85); font-weight:600; }
#help { position:absolute; inset:0; background:rgba(20,20,22,0.96);
        -webkit-backdrop-filter:blur(20px); display:none; flex-direction:column;
        padding:22px 26px; gap:2px; }
#help h2 { font-size:15px; margin-bottom:12px; }
#help .row { display:flex; justify-content:space-between; padding:6px 0;
             border-bottom:0.5px solid rgba(255,255,255,0.06); }
#help kbd { font:11px ui-monospace,monospace; background:rgba(255,255,255,0.12);
            padding:2px 7px; border-radius:5px; }
#help .hint { margin-top:14px; font-size:11px; color:rgba(235,235,245,0.5); }
</style></head><body><div id="panel">
<div id="q"><span class="icon">⌕</span><span class="text"></span></div>
<div id="list"></div>
<div id="foot"></div>
<div id="help">
  <h2>Clipboard controls</h2>
  <div class="row"><span>Move selection</span><span><kbd>↑</kbd> <kbd>↓</kbd></span></div>
  <div class="row"><span>Quick-paste item N (keeps order &amp; panel open)</span><span><kbd>1</kbd>–<kbd>9</kbd> <kbd>0</kbd></span></div>
  <div class="row"><span>Paste into active window</span><kbd>↩</kbd></div>
  <div class="row"><span>Paste &amp; keep panel open</span><kbd>⌘ ↩</kbd></div>
  <div class="row"><span>Copy to clipboard (manual paste)</span><kbd>⌘ C</kbd></div>
  <div class="row"><span>Quick Look</span><kbd>⌘ Y</kbd></div>
  <div class="row"><span>Save to Desktop</span><kbd>⌘ S</kbd></div>
  <div class="row"><span>Show in Finder</span><kbd>⌘ R</kbd></div>
  <div class="row"><span>Share</span><kbd>⌘ ⇧ S</kbd></div>
  <div class="row"><span>Delete entry</span><kbd>⌘ ⌫</kbd></div>
  <div class="row"><span>Clear all history</span><kbd>⌘ ⇧ ⌫</kbd></div>
  <div class="row"><span>Close panel</span><kbd>esc</kbd></div>
  <div class="hint">Type to search · press <kbd>?</kbd> to toggle this overlay</div>
</div>
</div>
<script>
let MAP = {}, order = [], visible = [], sel = 0, query = "", helpOn = false;
const KIND = { text:"text", rich:"rich", image:"image", file:"file", url:"url" };
const listEl = document.getElementById('list');
const qText  = document.querySelector('#q .text');
const footEl = document.getElementById('foot');
const helpEl = document.getElementById('help');

footEl.innerHTML =
  '<span><b>1–9</b> Quick paste</span><span><b>↩</b> Paste</span>' +
  '<span><b>⌘C</b> Copy</span><span><b>⌘Y</b> Quick Look</span>' +
  '<span><b>⌘⌫</b> Delete</span><span style="margin-left:auto"><b>?</b> Controls</span>';

function loadItems(items) {
  MAP = {}; order = items.map(i => { MAP[i.id] = i; return i.id; });
}

function setState(ids, s, q, h) {
  visible = ids; sel = s; query = q; helpOn = h; draw();
}

function drawQuery() {
  qText.textContent = '';
  if (query.length === 0) {
    const ph = document.createElement('span'); ph.className = 'ph';
    ph.textContent = 'Clipboard history'; qText.appendChild(ph);
  } else {
    qText.appendChild(document.createTextNode(query));
  }
  const caret = document.createElement('span'); caret.className = 'caret';
  qText.appendChild(caret);
}

function draw() {
  drawQuery();
  helpEl.style.display = helpOn ? 'flex' : 'none';
  listEl.innerHTML = '';
  if (visible.length === 0) {
    const e = document.createElement('div'); e.id = 'empty';
    e.textContent = order.length ? 'No matches' : 'No clipboard history yet';
    listEl.appendChild(e); return;
  }
  visible.forEach((id, i) => {
    const it = MAP[id]; if (!it) return;
    const row = document.createElement('div');
    row.className = 'item' + (i === sel ? ' sel' : '');
    const n = document.createElement('span'); n.className = 'num';
    n.textContent = i < 10 ? String((i + 1) % 10) : '';  // 1..9 then 0 for the 10th
    row.appendChild(n);
    const b = document.createElement('span');
    b.className = 'badge ' + (KIND[it.kind] || '');
    b.textContent = KIND[it.kind] || it.kind; row.appendChild(b);
    const t = document.createElement('span'); t.className = 'txt';
    t.textContent = it.preview; row.appendChild(t);
    if (it.thumb) { const im = document.createElement('img');
      im.className = 'thumb'; im.src = it.thumb; row.appendChild(im); }
    row.addEventListener('click', () => post({ action:'paste', id:id }));
    listEl.appendChild(row);
  });
  const cur = listEl.children[sel];
  if (cur && cur.scrollIntoView) cur.scrollIntoView({ block:'nearest' });
}

function post(o) { window.webkit.messageHandlers.clipMgr.postMessage(o); }

loadItems(]] .. rowsJSON .. [[);
setState(order.slice(), 0, "", false);
</script></body></html>]]
end

local screen = hs.screen.mainScreen():frame()
local W, H = 720, 520
local rect = {
    x = screen.x + (screen.w - W) / 2,
    y = screen.y + (screen.h - H) / 3,
    w = W, h = H,
}

local userContent = hs.webview.usercontent.new("clipMgr")

_G.clipboardMgrWebview = hs.webview.new(rect, { developerExtrasEnabled = false }, userContent)
    :windowStyle({ "borderless" })
    :transparent(true)               -- let the CSS rounded panel show through
    :level(hs.drawing.windowLevels.modalPanel)
    :deleteOnClose(false)

-- ── Open / close ──────────────────────────────────────────────────────────────
local function closePanel()
    _G.clipboardMgrOpen = false
    if _G.clipboardMgrTap then _G.clipboardMgrTap:stop() end
    if _G.clipboardMgrWebview then _G.clipboardMgrWebview:hide() end
end

local function showPanel()
    _G.clipboardMgrTargetApp = hs.application.frontmostApplication()
    panel.rows  = buildRows()
    panel.query = ""
    panel.sel   = 1
    panel.help  = false
    refilter()
    -- gsub guards against a clip's text closing the inline <script> early.
    -- Empty Lua table encodes as "{}" (object); force "[]" so JS gets an array.
    local json = ((#panel.rows > 0 and hs.json.encode(panel.rows)) or "[]"):gsub("</", "<\\/")
    _G.clipboardMgrWebview:html(panelHTML(json))
    _G.clipboardMgrWebview:show():bringToFront(true)
    _G.clipboardMgrOpen = true
    if _G.clipboardMgrTap then _G.clipboardMgrTap:start() end
end

-- ── Keyboard (global eventtap, live only while the panel is open) ──────────────
-- Borderless webviews can't take key focus, so we own the keyboard here. Every
-- keydown is consumed (the panel is modal); only the bindings below act.
local KEY = { ESC = 53, RET = 36, UP = 126, DOWN = 125, BKSP = 51,
              C = 8, S = 1, R = 15, Y = 16, V = 9, SLASH = 44 }

local function moveSel(delta)
    panel.sel = math.max(1, math.min(panel.sel + delta, #panel.visible))
    pushState()
end

_G.clipboardMgrTap = eventtap.new({ eventtap.event.types.keyDown }, function(e)
    local ok, err = pcall(function()
        local code = e:getKeyCode()
        local f    = e:getFlags()
        local cmd  = f.cmd and not f.alt and not f.ctrl

        -- Hyper+V again must toggle the panel shut (#12). While open, this tap
        -- swallows every key, so the global hotkey can't fire — handle it here.
        if code == KEY.V and f.cmd and f.ctrl and f.alt and f.shift then
            closePanel()
        elseif code == KEY.ESC then
            if panel.help then panel.help = false; pushState() else closePanel() end

        elseif code == KEY.UP then moveSel(-1)
        elseif code == KEY.DOWN then moveSel(1)

        elseif code == KEY.RET then
            local it = currentItem()
            if it then
                if f.cmd then repaste(it)          -- ⌘↩ paste & keep open
                else closePanel(); repaste(it) end -- ↩ paste & close
            end

        elseif code == KEY.BKSP then
            if cmd and f.shift then clearAll(); reloadRows()
            elseif cmd then
                local it = currentItem()
                if it then deleteItem(it.id); reloadRows() end
            elseif panel.query ~= "" then
                -- Drop one UTF-8 char (handles multi-byte tails).
                panel.query = panel.query:gsub("[\128-\191]*[^\128-\191]$", "")
                panel.sel = 1; refilter(); pushState()
            end

        elseif cmd and code == KEY.C then
            local it = currentItem()
            if it then stageClipboard(it, true) end
            closePanel()

        elseif cmd and code == KEY.Y then
            local it = currentItem(); if it then quickLook(it) end
        elseif cmd and code == KEY.S and f.shift then
            local it = currentItem(); if it then shareItem(it) end
        elseif cmd and code == KEY.S then
            local it = currentItem(); if it then saveToDesktop(it) end
        elseif cmd and code == KEY.R then
            local it = currentItem(); if it then revealInFinder(it) end

        elseif code == KEY.SLASH and f.shift then
            panel.help = not panel.help; pushState()

        elseif not f.cmd and not f.ctrl and not f.alt then
            local ch = e:getCharacters(false)
            -- Plain digit = quick-paste the Nth visible item (1..9, 0 = 10th). The
            -- panel stays open and history order is untouched, so the numbers stay
            -- stable across repeated pastes. A digit only reaches here unshifted
            -- (shift+digit yields a symbol), so digits never go to the search box.
            if ch and ch:match("^%d$") then
                local n   = tonumber(ch)
                local id  = panel.visible[(n == 0) and 10 or n]
                if id then local it = findById(id); if it then repaste(it) end end
            elseif ch and #ch >= 1 and ch:byte(1) >= 32 then
                -- Typing into the search box.
                panel.query = panel.query .. ch
                panel.sel = 1; refilter(); pushState()
            end
        end
    end)
    if not ok then closePanel() end -- never leave the keyboard captured on error
    return true                     -- modal: swallow every key while open
end)

-- Mouse clicks (JS → Lua). Keyboard never routes here.
userContent:setCallback(function(msg)
    local m = (type(msg) == "table" and msg.body) and msg.body or msg
    if type(m) ~= "table" then return end
    if m.action == "paste" then
        local item = findById(tonumber(m.id))
        closePanel()
        if item then repaste(item) end
    end
end)

-- ── Hotkey (toggle — issue #12) ───────────────────────────────────────────────
_G.clipboardMgrHotkey = hs.hotkey.bind(HYPER, "v", function()
    if _G.clipboardMgrOpen then closePanel() else showPanel() end
end)

-- ── CLI exposure (hs -c) ──────────────────────────────────────────────────────
_G.clipboardMgrShow  = showPanel
_G.clipboardMgrClear = clearAll
