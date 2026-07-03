# `clipboard_manager.lua` — deep dive

Native-style clipboard history for Hammerspoon. Hyper+V (`⌘⌃⌥⇧V`) toggles a
borderless, keyboard-driven panel that remembers the last 50 pasteboard items —
text, rich text (RTF/HTML), Markdown, images, files/folders, and URLs — and
survives reboots and config reloads.

This document explains how the module actually works, the non-obvious decisions
behind it, and the mistakes that are easy to reintroduce. If you only read one
section, read [Mistakes & gotchas](#mistakes--gotchas).

> File: `modules/clipboard_manager.lua` (~1590 lines, single file).
> Loaded by `init.lua` via `load("modules.clipboard_manager")`.

---

## 1. Mental model

Four independent pieces run at once, glued together by module-level state:

| Piece | What it is | When it runs |
|-------|-----------|--------------|
| **Poller** | `hs.timer.doEvery(0.5, …)` | Always. Watches `pb.changeCount()` and captures new clipboard contents. |
| **Key tap** | global `hs.eventtap` on `keyDown` + `flagsChanged` | Started only while the panel is visible. Drives all keyboard interaction. |
| **Mouse tap** | global `hs.eventtap` on left mouse down/drag/up | Started only while the panel is visible. Handles panel dragging and the "click outside to defocus" behavior. |
| **Webview** | `hs.webview` rendering an inline HTML/CSS document | Created on show, deleted on hide. Purely a *view* — it holds no logic. |

The webview is **borderless and cannot take keyboard focus** (see gotchas). That
single constraint explains most of the architecture: keyboard handling lives in a
global event tap, not in the webview, and clicks are relayed back to Lua through a
`usercontent` message channel.

```
      ┌──────────── poller (0.5s) ───────────┐
      │  pb.changeCount() changed?            │
      │    → makeEntryFromPasteboard()        │
      │    → pushEntry() → saveHistory()      │
      └───────────────────────────────────────┘
                        │ history[]  (module-level, mirrored to _G)
                        ▼
   Hyper+V ─► showPanel() ─► buildPanel() ─► webview + usercontent controller
                        │                          ▲   │
             key tap ───┤ keyboard                 │   │ JS click →
             mouse tap ─┤ drag / defocus           │   │ postMessage
                        ▼                          │   ▼
                   renderPanel() ─► renderHTML() ──┘  onWebMessage() → handleRowClick()
```

---

## 2. Where it lives and how to reload

- `~/.hammerspoon/init.lua` is a **symlink** to `Developer/hammerspoon/init.lua`.
- `~/.hammerspoon/modules` is a **symlink** to `Developer/hammerspoon/modules`.
- Hammerspoon resolves `require`/`load` from `hs.configdir` (`~/.hammerspoon`),
  so the *symlinked* file is what runs. Editing the repo file edits the live file.
- **Reload:** `touch /Users/armand/Developer/hammerspoon/init.lua` (the watcher in
  `init.lua` calls `hs.reload()` ~0.3s later), or `hs -c 'hs.reload()'`.

Line 1 is deliberate:

```lua
package.loaded["modules.clipboard_manager"] = nil
```

It forces a fresh load every reload even if something `require`d the module,
so edits always take effect.

### Surviving reloads

A reload throws away every Lua value **except** globals on `_G`. The module
therefore stashes long-lived things on `_G` and tears them down at the top of the
file before rebuilding:

```lua
_G.clipboardMgrHistory   -- the history table (also survives via hs.settings)
_G.clipboardMgrTimer     -- poller
_G.clipboardMgrKeyTap    -- keyboard tap
_G.clipboardMgrMouseTap  -- mouse tap
_G.clipboardMgrWebview   -- panel
_G.clipboardMgrQLTask    -- running Quick Look process (so it can be toggled)
_G.clipboardMgrTasks     -- fire-and-forget hs.task handles (kept from GC)
_G.clipboardMgrHotkey    -- Hyper+V binding
_G.clipboardMgrShow      -- exposed entry point, callable via `hs -c 'clipboardMgrShow()'`
```

If you add a new persistent tap/timer/hotkey, **add a matching teardown line at
the top** or reloads will leak duplicates (two taps both firing, etc.).

---

## 3. Data model — the entry table

Every history item is a plain Lua table. The important fields:

| Field | Type | Notes |
|-------|------|-------|
| `kind` | string | `"text"` \| `"richtext"` \| `"markdown"` \| `"image"` \| `"file"` \| `"url"`. Drives rendering, restore, save, preview. |
| `title` | string | One-line label shown in the row (clipped to 96 chars). |
| `subtitle` | string | Secondary line (e.g. joined file paths, `"1920x1080 image"`). |
| `text` | string? | Plain-text representation, used for search/preview/restore fallback. |
| `urls` | string[] | URL **strings** (http/https or `file://…`). |
| `files` | string[] | Resolved POSIX paths for `kind == "file"`. |
| `types` | string[] | UTIs present on the pasteboard at capture time. |
| `data` | table | `UTI → raw bytes` (from `pb.readAllData()`). **In-memory only.** |
| `image` | `hs.image`? | **In-memory only** (userdata). |
| `styledText` | `hs.styledtext`? | **In-memory only** (userdata). Used to restore RTF. |
| `imageFile` | string? | Path to a PNG mirror in `CACHE_DIR`. Persisted; rehydrates `image` after reload. |
| `signature` | string | Dedup key (see below). |
| `created` | number | `os.time()`. |

### Persisted vs in-memory

`serializeEntry()` (→ `hs.settings.set`) stores **only** plain data:
`kind, title, subtitle, text, urls, files, imageFile, types, signature, created`.

It deliberately **drops** `data`, `image`, and `styledText` because those are
either userdata (can't be serialized) or large raw blobs. On the next load,
`normalizeHistory()` rehydrates images from `imageFile`. RTF `styledText` is
**not** rehydrated, so after a reload a rich-text entry falls back to pasting its
plain `text` (acceptable; the alternative is bloating settings with RTF blobs).

### The signature (dedup)

`signatureFor(data, types, text, urls)` builds a stable string from the sorted
UTIs (name + length + 64-char prefix), the type list, the URLs, and a 256-char
text prefix. `pushEntry()` removes any existing entry with the same signature
before inserting the new one at the top — so genuinely new captures dedup
instead of duplicating. Persisted entries carry their signature so dedup keeps
working across reloads.

Restoring an older history entry for paste/copy is handled separately:
`restoreClipboard()` sets a one-shot `skippedRestore` token, and the poller
drops that next self-generated capture if the signature matches. That keeps
reused items in their current position until the user explicitly promotes one.

> **Watch:** `signatureFor` concatenates `urls`. If `urls` ever contains a
> non-string (it used to — see gotcha #1), this line throws and the whole capture
> is silently dropped.

---

## 4. Capture flow (the poller)

```
every 0.5s:
  c = pb.changeCount()
  if c == lastChange: return            -- cheap fast-path, no allocation
  lastChange = c
  pushEntry(makeEntryFromPasteboard())
  if panelVisible: renderPanel()
```

`makeEntryFromPasteboard()` reads every representation Hammerspoon exposes
(`contentTypes`, `readAllData`, `readString`, `readImage`, `readStyledText`,
`readURL`, plus file UTIs), then classifies `kind` in priority order:

```
files present        → file
image present        → image
Markdown UTI/heuristic → markdown
rich UTI (RTF/HTML)  → richtext
URL present/heuristic → url
otherwise            → text
```

The whole poller body runs inside `guarded("capture", …)`, which `xpcall`s and, on
error, shows an alert + logs to the Hammerspoon console. This is a double-edged
sword — see gotcha #6.

---

## 5. The panel

### Why a webview, and why it's this awkward

`hs.webview` gives us real HTML/CSS — the only practical way to get the
translucent, rounded, native-looking list. But the panel is created with
`:windowStyle(0)` (borderless) and `:allowTextEntry(false)`, which means:

- **It never becomes the key window.** Keystrokes do not go to it. All keyboard
  handling must happen in a global `hs.eventtap` (the key tap).
- **We still get mouse events** inside it (that's how native HTML5 drag-out to
  Finder works), so clicks *can* be handled — but the handler has to live in JS
  and message back to Lua (the `usercontent` channel).

### Three view modes

`renderHTML()` produces one of three layouts based on `detailMode`:

| `detailMode` | Layout | Width | Trigger |
|--------------|--------|-------|---------|
| `nil` | List only | `PANEL_W` = 680 | default |
| `"preview"` | List + preview pane (grid `360px 1fr`) | `DETAIL_W` = 980 | `Space` |
| `"help"` | Compact actions sheet | `PANEL_W` = 680 | `/` or `?` |

`panelFrame()` picks the width from `detailMode` and keeps the panel's cached
`x/y` so it doesn't jump position when it widens/narrows. `renderPanel()`
re-applies the frame and re-sets the whole HTML on every state change (there is no
incremental DOM update — the doc is small, so a full re-render is simplest).

The position is also persisted via `hs.settings` (`clipboardMgr.frame.v1`). That
is necessary because the panel is intentionally deleted on close to stay
lightweight, so the next show has to rebuild both the webview and its last known
origin from plain Lua data.

When there is no saved origin, the panel uses a "home" position: horizontally
centered, but a little above dead-center. Dragging back near that home target
shows full-screen crosshair guides and snaps the panel back into place once the
origin is very close.

### Dragging the panel & dragging rows

The mouse tap distinguishes three intents on `leftMouseDown` inside the frame:

1. **Cmd-held or on the title bar** (`isInDragHandle`, top `QUERY_H+8` px) →
   start moving the whole panel (tap returns `true`, consumes the event, and
   updates `panelFrameCache` on drag). Near the home position, drag feedback also
   shows full-screen guide lines and snaps back once the frame is close enough.
2. **On a row** → return `false` so WebKit gets the event and can start a native
   HTML5 drag (drop a file/image/text into Finder or another app). Row markup
   sets `draggable="true"` and a `data-drag` payload.
3. **Scroll wheel / two-finger scroll over the list** → move the fixed
   visible-row viewport through history without changing the overall panel size.
   The current `visibleFirst` row still drives the `⌘1`–`⌘9` badges, so the
   numbers always map to what is on screen.
4. **Outside the frame** → set `panelHasInput = false` and pass through. This is
   the "float while you work elsewhere" behavior (see below).

### Click-to-select / click-to-paste

Because the webview can't focus, plain clicks are handled in JS and relayed:

```js
row.addEventListener('click', () =>
  window.webkit.messageHandlers.clipboardMgr.postMessage({type:'click', index: …}))
```

Lua side: `buildPanel()` attaches an `hs.webview.usercontent` controller named
`clipboardMgr`; `onWebMessage → handleRowClick(index)`:

- click a **non-selected** row → select it (re-render);
- click the **already-selected** row → paste it and close.

A click and a native drag are mutually exclusive in WebKit (a completed drag
suppresses the `click`), so dragging a row out never accidentally pastes.

**Hover** is driven the same way, for the same reason: a non-key window gets no
`mouseMoved` events, so CSS `:hover` never fires. The mouse tap listens for
`mouseMoved`, and while the pointer is inside the panel frame calls
`updateHover(point, frame)` → `webview:evaluateJavaScript("window.__hoverAt(x,y)")`
with page-relative coords. `__hoverAt` runs `document.elementFromPoint`, finds the
`.row`, and toggles a `.hover` class (styled identically to `:hover`). See
gotcha #4.

---

## 6. Keyboard handling

The key tap listens for `keyDown` **and** `flagsChanged` (the latter only so we
can detect Cmd being held for the number badges). Structure of the handler:

1. `if not panelVisible: return false` — do nothing when hidden.
2. `flagsChanged` → update `cmdHeld`, re-render, **return false** (never consume a
   modifier).
3. `Hyper+V` → close. `Hyper+1`–`Hyper+9` → paste the visible numbered item while
   keeping the panel open. `Esc` → close. **These act regardless of focus** — they
   are checked *before* the `panelHasInput` gate.
4. `if not panelHasInput: return false` — opening the panel sets this to `true`,
   so arrows, Return, Space, and filter typing work immediately. Clicking outside
   the panel sets it to `false`, which lets ordinary typing keep going to the app
   underneath while the list stays visible.
5. Everything else: navigation, actions, filter typing.

### Full bindings

| Key | Action |
|-----|--------|
| `↩` | Paste selected item, close panel |
| `⌘↩` | Paste selected item, keep panel open |
| **Hold `⌘`** | Show `1–9` badges beside the visible rows |
| `⌘1`–`⌘9` | Paste the *n*-th visible item, keep panel open |
| `Hyper+1`–`Hyper+9` | Paste the *n*-th visible item, keep panel open, even while working in another app |
| `⌘C` | Copy item back to the system clipboard |
| `⌘T` | Move the selected history entry to the top |
| `Space` | Toggle the preview pane |
| `⌘Y` | Toggle Quick Look |
| `⌘S` | Save item to Desktop |
| `⌘O` | Open (files / URLs) |
| `⌘R` | Reveal in Finder (files) |
| `⌘⌫` | Delete selected entry |
| `⌘⇧⌫` | Clear all entries |
| `↑ ↓` / `PgUp PgDn` / `Home End` | Move selection |
| mouse wheel / two-finger scroll | Scroll the visible history window |
| *type any char* | Append to the filter query |
| `⌫` | Edit (backspace) the filter query |
| `/` or `?` | Toggle the compact actions sheet |
| `Esc` or `Hyper+V` | Close |

> The number badges map to **visible** rows: `⌘n` pastes `filtered[visibleFirst + n − 1]`,
> where `visibleFirst` is the first row currently scrolled into view (set in
> `renderHTML`). So the numbers always match what you see.

### Paste mechanics

`pasteItem(item, keepOpen)`:

1. `restoreClipboard(item)` puts the item back on the system pasteboard (typed
   Cocoa objects where possible: file URLs, `hs.image`, `hs.styledtext`; plain
   `setContents` otherwise).
2. Focus the window that was frontmost when the panel opened (`previousWindow`).
3. Synthesize the paste keystroke:
   - **rich text → `⌘⌥V`**, everything else → `⌘V`.
   - This is a deliberate cross-module dependency: `paste_manager.lua` rebinds
     plain `⌘V` to *strip* formatting and `⌘⌥V` to *keep* it. Sending `⌘⌥V` for
     rich items bypasses the stripper so formatting survives.
4. The key tap is stopped around the synthetic keystroke so we don't re-enter our
   own handler; if `keepOpen`, it restarts after 0.16s and re-fronts the panel.

---

## 7. Actions in brief

- **Save (`⌘S`)** writes to `~/Desktop`, choosing an extension by kind
  (`.png/.md/.rtf/.html/.url/.txt`). Files/folders are copied with a
  fire-and-forget `/bin/cp -R` into a timestamped `Clipboard Files …` folder.
- **Quick Look (`⌘Y`)** launches `qlmanage -p` as an `hs.task`, stored in
  `_G.clipboardMgrQLTask`. A second press **terminates** that task to close the
  panel (a genuine toggle). Non-file items are first written to a temp file.
- **Open / Reveal** shell out to `/usr/bin/open` (`-R` for reveal).
- `uniquePath()` avoids clobbering existing Desktop files by appending ` 2`, ` 3`…

---

## 8. Persistence

- Key: `hs.settings` under `clipboardMgr.history.v2`.
- Panel origin: `hs.settings` under `clipboardMgr.frame.v1`.
- Images mirrored as PNG into
  `$TMPDIR/hammerspoon-clipboard-manager/` (`CACHE_DIR`).
- `MAX_ITEMS = 50`; oldest entries fall off the end on each `pushEntry`.

> `$TMPDIR` can be cleared by macOS. Image *entries* survive a reload because the
> path is persisted, but if the OS purges the temp dir the PNG (and thus the
> thumbnail/restore) is gone. Moving image caches to `~/Library/Caches` would make
> them durable — not done yet (YAGNI until it bites).

---

## Mistakes & gotchas

These are the traps. Most of them have already bitten this file once.

### 1. `hs.pasteboard.readURL` returns NSURL **tables**, not strings

`readURL()` returns `{ url = "file://…", filePath = "/real/path", __luaSkinType="NSURL" }`
and `readURL(true)` returns a **list** of those. Older code treated them as
strings; the moment one hit `signatureFor` (`"url:" .. url`) or `setContents`, Lua
threw *"attempt to concatenate a table value"*. Because capture runs inside
`guarded`, the error was swallowed and **every file/URL copy silently vanished**
from history.

Fix: `readURLStrings()` flattens each NSURL via `urlToString()`, which **prefers
`.filePath`** (see #2) and falls back to `.url`. Never assume `readURL` gives you
strings.

### 2. Finder multi-file copies use opaque `/.file/id=…` reference URLs

When you copy several files in Finder, each NSURL's `.url` can be a *reference*
URL like `file:///.file/id=6571367.15352560/` — useless as a path
(`hs.fs.attributes` fails on it, reveal/paste break). The resolved POSIX path is
in the NSURL's `.filePath`. That's why `urlToString` returns
`pathToFileURL(u.filePath)` when `filePath` exists. Symptom if you regress: file
rows show `/.file/id=…` in the subtitle and copy/reveal fail.

### 3. The Lua `x and nil or y` toggle pitfall

```lua
detailMode = detailMode == "help" and nil or "help"   -- ❌ ALWAYS yields "help"
```

`a and nil` evaluates to `nil`, then `nil or "help"` is `"help"` — so this
"toggle" can never turn off. Both the help (`/`) and preview (`Space`) toggles had
this bug; they'd open but never close. Correct form puts the truthy value first:

```lua
detailMode = (detailMode ~= "help") and "help" or nil   -- ✅ real toggle
```

Any time you write a toggle where one branch is `nil`/`false`, use this shape.

### 4. A borderless webview cannot take keyboard focus

`:windowStyle(0)` + `:allowTextEntry(false)` means the panel is never the key
window. **Do not** try to read keys from the webview or add an `<input>` — it
won't receive them. All keyboard input goes through the global key tap; that is by
design, not a workaround waiting to be removed. It's also why the "filter query"
is drawn by us from a Lua `query` string rather than being a real text field.

The same "never the key window" fact breaks **mouse hover**: macOS delivers
`mouseMoved` only to the key window, so native CSS `:hover` never fires (clicks
still work — `leftMouseDown` reaches non-key windows). Hover is therefore driven
manually from the mouse tap: `mouseMoved` → `updateHover` →
`evaluateJavaScript("window.__hoverAt(x,y)")`, which hit-tests with
`elementFromPoint` and toggles a `.hover` class. If hover ever "does nothing",
this is why — don't reach for a CSS fix.

### 5. Clicks need the `usercontent` message channel

Since keys don't reach the webview, and we can't call Lua from JS directly, row
clicks are relayed with
`window.webkit.messageHandlers.clipboardMgr.postMessage(...)` → the controller's
`setCallback`. If clicks stop working, check: (a) the controller name matches on
both sides (`"clipboardMgr"`); (b) `webview.new(frame, {}, controller)` is passed
the controller; (c) you rebuilt the panel (the controller is attached in
`buildPanel`, and the panel is recreated on every show).

The message `index` arrives as a **float** (`2.0`) through JSON; `handleRowClick`
`math.floor`s it. Without that, `"2.0 of 50"` shows in the counter and table
lookups get fragile.

### 6. `guarded()` swallows errors — great for resilience, terrible for debugging

Wrapping capture/handlers in `xpcall` means one weird clipboard format can't take
down the config. The cost: **failures are invisible unless you look.** When
something "just doesn't capture", read the Hammerspoon console:

```bash
hs -c 'print(hs.console.getConsole())' | tr -d '\000' | grep -iE 'fail|error|:[0-9]+:'
```

Every real bug in this file so far first showed up as a caught error there, not as
a crash.

### 7. Reloads wipe userdata; persistence must be plain data

`hs.settings` can't serialize `hs.image` / `hs.styledtext` / raw userdata. If you
add a field holding userdata, either **exclude it from `serializeEntry`** or
mirror it to a file (like `imageFile`). Forgetting this makes `saveHistory` throw
(again, swallowed) or silently persist nothing.

### 8. Testing the GUI: two permission traps

- **`cliclick`** (synthetic clicks) needs **Accessibility** permission for the
  *terminal/host process actually spawning it*. Granting it to a different app, or
  granting mid-session without relaunching that process, still fails with
  *"Accessibility privileges not enabled."* When it won't cooperate, exercise the
  click path directly instead:
  `webview:evaluateJavaScript("window.webkit.messageHandlers.clipboardMgr.postMessage({type:'click',index:2})")`.
- **`screencapture`** needs **Screen Recording** permission and often fails here
  with *"could not create image from display."* Use Hammerspoon's own snapshot,
  which works without it:
  ```lua
  hs -c 'local f=_G.clipboardMgrWebview:frame(); hs.screen.mainScreen():snapshot(f):saveToFile("/tmp/panel.png")'
  ```

### 9. Synthetic keystrokes re-enter the key tap

`eventtap.keyStroke` posts real events that our own global tap will see. Paste
would re-trigger the handler, so `postPasteForItem` **stops the key tap** around
the synthetic `⌘V`. If you add code that synthesizes keys, stop/restart the tap or
guard against recursion.

### 10. `panelHasInput` — the panel intentionally floats

The panel opens with `panelHasInput = true`, so keyboard navigation and filtering
work immediately after `Hyper+V`; users should not have to click the webview
first. After you click outside the panel, `panelHasInput` becomes `false` and the
key tap passes ordinary keys through (so you can keep working, and new copies
still get captured while the list is visible). Only `Hyper+V` and `Esc` still act.
If you expect a shortcut to work "always", it must be checked **before** the
`panelHasInput` gate (that's exactly the fix that made `Esc` close from anywhere).

### 11. Preview width jumps are deliberate; help stays compact

`panelFrame()` returns `DETAIL_W` (980) only for preview mode and `PANEL_W`
(680) otherwise, reusing cached `x/y` and persisting that origin through
`clipboardMgr.frame.v1`. This is how you verify mode in a test without reading a
private local: `_G.clipboardMgrWebview:frame().w` is 680 in list/help mode and
980 in preview.

The default "home" frame is also intentional: it sits slightly above exact
screen center so the drag-to-reset guides feel more like native macOS floating
panels than a mathematically centered rectangle.

### 12. Row-drag payloads and the image-file trick

Finder converts a dragged `data:image/…` URL into a text file, so image rows must
advertise the **cached PNG path** (`pathToFileURL(item.imageFile)`) as their drag
payload, not the data URL. `dragPayload()` encodes this per kind; keep it in sync
if you add a kind.

### 13. Restoring an item is intentionally not a recency update

Using an old entry via `⌘C`, `↩`, or `⌘↩` writes it back to the system
pasteboard, which would normally look like a new capture and bump it to the
front. The module now tags that restore and ignores the next matching poller
capture, so history order stays stable. `⌘T` is the explicit "move this to the
top" action.

---

## Debugging / verification playbook

```bash
# Reload after an edit
touch /Users/armand/Developer/hammerspoon/init.lua      # or: hs -c 'hs.reload()'

# Did it load clean?
hs -c 'print(hs.console.getConsole())' | tr -d '\000' | grep -iE 'fail|error|:[0-9]+:'

# Inspect captured history
hs -c 'local e=_G.clipboardMgrHistory[1]; print(e.kind, e.title); print(hs.inspect(e.files))'

# Open the panel from the CLI (bypasses the hotkey)
hs -c 'clipboardMgrShow()'

# Snapshot the panel (no Screen Recording perm needed)
hs -c 'local f=_G.clipboardMgrWebview:frame(); hs.screen.mainScreen():snapshot(f):saveToFile("/tmp/panel.png")'

# Simulate a captured file / multi-file copy
hs -c 'hs.pasteboard.writeObjects({hs.sharing.fileURL(os.getenv("HOME").."/a.txt"), hs.sharing.fileURL(os.getenv("HOME").."/b.txt")})'

# Drive a click without cliclick
hs -c '_G.clipboardMgrWebview:evaluateJavaScript("window.webkit.messageHandlers.clipboardMgr.postMessage({type:\"click\",index:2})")'
```

**Golden rule for this file:** when something "used to work", check `git log` /
`git diff` and the console *before* theorizing — every regression here has left a
caught error in the console, and Hammerspoon/macOS API return shapes (like
`readURL`) change between versions.

---

## Extending

- **New kind:** classify it in `makeEntryFromPasteboard`, add a `typeBadge`
  label, a `restoreClipboard` branch, a `previewHTML` branch, a `dragPayload`
  branch, and (if savable) a `saveItem`/`writeItemToTemporaryFile` branch. Decide
  what persists (`serializeEntry`).
- **New binding:** add a branch in the key-tap `if/elseif` chain, add a row to
  `actionRows()` so it shows in the help sheet, and decide whether it should
  affect clipboard recency or preserve order like the restore actions do.
- **New persistent tap/timer:** create it on `_G`, and add a teardown line at the
  top of the file.

## Tunables (top of file)

`MAX_ITEMS` 50 · `POLL` 0.5s · `PANEL_W` 680 · `DETAIL_W` 980 · `PANEL_H` 430 ·
`VISIBLE_ROWS` derived from panel height and row CSS so selection never runs onto
clipped rows · `HYPER` `⌘⌃⌥⇧` · `SETTINGS_KEY` `clipboardMgr.history.v2` ·
`PANEL_FRAME_KEY` `clipboardMgr.frame.v1`.
