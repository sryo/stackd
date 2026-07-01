# `sd.*` API reference

The complete author-facing JavaScript API. Everything is on the global `sd`. Source of truth: `Runtime/api.js`; permissions cross-checked against `Sources/Permissions.swift` and `Sources/Channels.swift`.

> **Prefer templates?** For zero-config, declarative use, `{{ }}` placeholders with `sd-each` / `sd-if` bind channels straight into the DOM — no `subscribe` call per element, and permissions are inferred. This page is for explicit, programmatic control. See [The template engine](template-engine.md).

**Conventions**

- **channel** = a signal with `.subscribe(fn[, {interval}])`, `.peek()`, `.value`, `.first(pred?)`, and Proxy fall-through (so `sd.battery.percent` reads `.value.percent`). Channels are **global** (process-wide, shared across stacks). See [The reactive model](../concepts/reactive-model.md).
- `.subscribe(fn, { interval: N })` throttles only *poll-driven* channels (tagged *poll-tunable* below); event-driven channels ignore it.
- Coordinates are top-left-origin global screen space unless noted.
- **Permission** = the manifest `permissions:` string the daemon gates on (auto-inferred from `sd.<perm>.` source references except composites like `menubar.item`). See [Permissions](../concepts/permissions.md).
- For `{{ }}` / `sd-each` / `sd-if` / `sd-on:click`, see [The template engine](template-engine.md).

---

## Namespace index

| Namespace | Exposes | Global / Scoped | Permission |
|---|---|---|---|
| `sd.app` | Frontmost-app + app-activated channels | Global channels | `app` |
| `sd.appearance` | Light/dark + accent channel | Global channel | `appearance` |
| `sd.applescript` | In-process AppleScript / JXA runner | RPC | `applescript` |
| `sd.apps` | Running-apps list/deltas + launch/focus/kill/hide + per-pid AX | Channels + RPC | `apps` |
| `sd.audio` | Default in/out device channels, per-process audio, volume/mute, device enum | Channels + RPC | `audio` |
| `sd.ax` | Generic accessibility (AXUIElement) tree walker | RPC (handle-based) | `ax` |
| `sd.bang` | Fire/declare cross-stack bangs | RPC + callbacks | (ungated) |
| `sd.battery` | Battery state channel | Global channel | `battery` |
| `sd.bind` | Reactive DOM binding helper (pure JS) | Helper | none |
| `sd.bluetooth` | Paired Bluetooth peripherals | RPC | `bluetooth` |
| `sd.bonjour` | mDNS publish / browse | RPC + per-handle channel | `bonjour` |
| `sd.broadcasts` | DistributedNotificationCenter subscribe | RPC + callbacks | `broadcasts` |
| `sd.caffeinate` | Sleep/lock channel + power-assertion setter | Channel + RPC | `caffeinate` |
| `sd.calendar` | EventKit events/reminders/create + change channel | Channel + RPC | `calendar` |
| `sd.camera` | Camera device list channel + one-shot frame + stream | Channel + RPC | `camera` |
| `sd.cursor` | Cursor warp / read | RPC | `cursor` |
| `sd.defaults` | Read another app's `defaults` | RPC | `defaults` |
| `sd.disks` | Mounted volumes list | RPC | `disks` |
| `sd.display` | Per-display channels, brightness, snapshot, point/window lookup | Channels + RPC | `display` |
| `sd.displayLink` | Vsync frame-tick channel | Global channel | `displayLink` |
| `sd.events` | Synthesize input + eventtap gating/registration | RPC + slot handlers | `events` |
| `sd.fs` | File read/write/list/stat/watch + xattr | RPC + watch callbacks | `fs` |
| `sd.handlers` | Generic slot-handler registration | Slot handlers | (per-kind) |
| `sd.host` | Host info, load channel, disk IO | Channel + RPC | `host` |
| `sd.hotkey` | Dynamic Carbon hotkeys + modal modes + slot handlers | RPC + callbacks | `hotkey` |
| `sd.httpserver` | Long-running HTTP server | RPC + request callbacks | `httpserver` |
| `sd.icons` | App/file icon PNG data URLs | RPC | `icons` |
| `sd.input` | Keyboard layout channel + focused-text AX surface | Channel + RPC | `input` |
| `sd.location` | CoreLocation fix channel | Global channel | `location` |
| `sd.media` | Now-playing channel + transport commands | Channel + RPC | `media` |
| `sd.menu` | Native NSMenu popup at cursor | RPC | `menu` |
| `sd.menubar` | Menu-bar suppress/restore, AX item enum/channels, NSStatusItem | Channels + RPC | `menubar` / `menubar.item` |
| `sd.mouse` | Cursor position channel + warp | Channel + RPC | `mouse` |
| `sd.net` | Wi-Fi/LAN/path/throughput channels | Global channels | `net` |
| `sd.nlp` | NaturalLanguage: lang ID, tokens, lemmas, similarity | RPC | `nlp` |
| `sd.notify` | Notification Center banners | RPC | `notify` |
| `sd.overlay` | WebKit overlay pinned to a foreign window | RPC + handle | `overlay` |
| `sd.pasteboard` | Clipboard channel + get/set | Channel + RPC | `pasteboard` |
| `sd.privacy` | Camera/mic/screen capture in-use channel + one-shot | Channel + RPC | `privacy` |
| `sd.proc` | Run subprocess (buffered + streamed) | RPC + stream callbacks | `proc` |
| `sd.screen` | Per-instance current-screen info (sync) | Scoped (sync) | none |
| `sd.sensors` | Mac internal sensors (temps/fans/voltage) channel | Global channel | `sensors` |
| `sd.settings` | Per-stack k/v persistence | RPC | `settings` |
| `sd.shortcuts` | Run a macOS Shortcut by name | RPC | `shortcuts` |
| `sd.sound` | Play system/file sounds, beep | RPC | `sound` |
| `sd.spaces` | Spaces list channel + per-window/space queries | Channel + RPC | `spaces` |
| `sd.speech` | TTS speak/stop/voices + STT listen | RPC + per-handle channel | `speech` |
| `sd.spotlight` | Spotlight find (one-shot) + live subscribe | RPC + per-handle channel | `spotlight` |
| `sd.sqlite` | Embedded SQLite (open/exec/query/close) | RPC + handle | `sqlite` |
| `sd.thumbnails` | QuickLook thumbnail generation | RPC | `thumbnails` |
| `sd.timer` | Reload-safe timeout/interval/debounce/throttle (pure JS) | Helper | none |
| `sd.touchdevice` | Raw per-finger trackpad frames channel | Global channel | `touchdevice` |
| `sd.tpl` | Tagged-template DOM builder (pure JS) | Helper | none |
| `sd.update` | Pending macOS software updates | RPC | `update` |
| `sd.urlhandler` | Custom URL-scheme handlers | RPC + callbacks | `urlhandler` |
| `sd.usb` | Attached USB devices channel | Global channel | `usb` |
| `sd.util` | debounce / throttle (pure JS) | Helper | none |
| `sd.vision` | Vision: OCR, faces, feature-print, subject mask, body pose | RPC | `vision` |
| `sd.window` | THIS stack's own panel | Scoped (self) | (self) |
| `sd.windows` | All-windows channels + per-id AX getters/setters + batch | Channels + RPC | `windows` |

---

## Per-namespace detail

### `sd.app` — frontmost-app channels · `app`
- `sd.app.frontmost` *(channel)* — `{ app, pid, bundleId, … }`. Updates when the frontmost app changes.
- `sd.app.activated` *(channel)* — same shape; fires specifically on app-activation events.

### `sd.appearance` — appearance channel · `appearance`
- `sd.appearance` *(channel)* — `{ dark, accentHex, … }`. Updates on light/dark / accent change.

### `sd.applescript` — script runner · `applescript`
- `run(source, opts?) → Promise<{ ok, result, error? }>` — AppleScript, or JXA via `opts.language:"javascript"`; `opts.timeout` default 10s. `result` preserves return type.

### `sd.apps` — running apps · `apps`
- `sd.apps.running` *(channel, default `[]`)* — `[{pid, bundleId, name, active, hidden, launchedAt?}]`.
- `sd.apps.changed` *(channel, delta, non-replayable)* — `{ added, removed, changed }`.
- `launch(bundleId)` · `focus(bundleId)` · `kill(bundleId, force?)` — each `→ Promise`.
- `hide(bundleIdOrPid)` (string=bundle, number=pid) · `unhide(pid)` — `→ Promise`.
- `menu(pid) → Promise<tree|null>` — AX menu tree `{title, role, children, shortcut?, enabled?}`.
- `findMenuItem(pid, path[]) → Promise<{title,role,enabled,marked?}|null>` · `selectMenuItem(pid, path[]) → Promise<boolean>`.
- `visibleWindows(pid) → Promise<[{id,app,pid,title,frame,onscreen}]>`.
- `focusedWindow(pid)` · `mainWindow(pid)` `→ Promise<number|null>` · `allWindows(pid) → Promise<number[]>`.
- `isFrontmost(pid)` · `isHidden(pid)` `→ Promise<boolean>`.

### `sd.audio` — audio devices · `audio`
- `sd.audio.output` *(channel)* — `{ name, volume, muted, deviceName }` for default output.
- `sd.audio.input` *(channel)* — same shape for default input (reading does NOT trigger mic TCC).
- `sd.audio.processes` *(channel)* — `[{ pid, bundleId, name, playingOutput }]`.
- `setVolume(v)` · `setMuted(bool)` · `setInputVolume(v)` · `setInputMuted(bool)` `→ Promise`.
- `devices(opts?) → Promise<[{id,name,manufacturer?,transportType?,uid?,isDefault}]>` — `opts.scope:"input"|"output"` (default output).
- `setDefaultDevice(id, scope?) → Promise`.

### `sd.ax` — accessibility tree · `ax`
Handle-based; handles are opaque ints owned by this stack — release them.
- `focused() → Promise<dict>` (back-compat focused element).
- `application(pid)` · `system()` · `systemElementAtPosition(x,y)` · `focusedElement()` · `focusedElementSystemWide()` `→ Promise<handle>`.
- `attributeNames(h)` · `attribute(h,name)` · `attributes(h)` · `parameterizedAttributeNames(h)` · `parameterizedAttribute(h,name,param)`.
- `actionNames(h)` · `isAttributeSettable(h,name)` · `setAttribute(h,name,value)` · `performAction(h,action)`.
- `children(h)` · `parent(h)` · `role(h)` · `release(h)` · `releaseAll()`.

### `sd.bang` — cross-stack bangs · ungated
- `sd.bang(name, detail?) → Promise<count>` — fire to stacks whose manifest `handles` contains `name`.
- `sd.bang.declare(name) → { name, emit(detail?), on(fn)→disposer }` — typed registry; `on()` auto-registers (no manifest entry needed).
- Window-lifecycle bangs are documented under [`sd.windows`](#sdwindows--all-windows--windows) and [The reactive model](../concepts/reactive-model.md#window-lifecycle-bangs).

### `sd.battery` — battery · `battery`
- `sd.battery` *(channel)* — e.g. `sd.battery.percent`, charging state.

### `sd.bind` — reactive binding helper · none
- `sd.bind(target, signal|signal[], fmt?) → disposer` — see [Template engine → sd.bind](template-engine.md#sdbindtarget-signal-fmt--dispose).

### `sd.bluetooth` — Bluetooth · `bluetooth`
- `paired() → Promise<[{address, connected, name?, classOfDevice?, services?}]>` — triggers Bluetooth TCC on first use.

### `sd.bonjour` — mDNS · `bonjour`
- `publish(opts) → Promise<{id, stop()}|null>` — `opts:{name, type, port, txt?}`.
- `browse(type) → { id, subscribe(fn)→unsub, stop() }` — `fn` gets `[{name,type,host?,port?,txt}]` (full set each time).

### `sd.broadcasts` — distributed notifications · `broadcasts`
- `subscribe(name, fn) → Promise<id|null>` — NSDistributedNotificationCenter (e.g. `"com.apple.screenIsLocked"`).
- `unsubscribe(id) → Promise` · `observe`/`unobserve` (back-compat aliases).

### `sd.caffeinate` — sleep/lock + power assertions · `caffeinate`
- `sd.caffeinate` *(channel)* — `{ sleeping, locked }`.
- `assert({type, reason?}) → Promise<{id, release()}|null>` — `type:"display"|"system"|"userActivity"`. Released on unload.

### `sd.calendar` — EventKit · `calendar`
- `sd.calendar.observe` *(channel)* — fires `{ ts }` on store change; re-fetch on signal.
- `events(opts) → Promise<[{identifier,title,start,end,allDay,calendar,location?,notes?,url?}]>` — `opts:{from,to,calendarIds?}` (epoch secs). Calendar TCC.
- `list() → Promise<[{identifier,title,source,type,allowsModify,color?}]>`.
- `reminders(opts?) → Promise<[{identifier,title,priority,completed,list,due?,notes?}]>` — separate Reminders TCC.
- `createEvent(opts) → Promise<id|null>` — `{calendarId,title,start,end,location?,notes?,allDay?}`.

### `sd.camera` — camera · `camera`
- `sd.camera` *(channel, default `[]`)* — `[{id,name,position,isInUse,manufacturer?}]`. Enumeration does NOT trigger TCC.
- `frame(opts?) → Promise<{dataURL,width,height}|null>` — first call triggers Camera TCC. `opts:{deviceId?,format?,quality?,timeoutSeconds?}`.
- `stream(opts?) → { id, subscribe(fn)→unsub, stop() }` — `{dataURL,width,height,ts}` per tick. `opts:{deviceId?,format?,quality?,fps?(10,max60)}`. LED on for stream lifetime.

### `sd.cursor` — cursor · `cursor`
- `setPosition({x, y, display?}) → Promise` — `display` (CGDirectDisplayID) makes coords display-local.
- `position() → Promise<{x,y}>` — top-left global.

### `sd.defaults` — defaults reader · `defaults`
- `read(bundleId, key) → Promise<value>`.

### `sd.disks` — volumes · `disks`
- `list() → Promise<[{name,mountPoint,fs?,removable?,ejectable?,size?,internal?}]>`.
- Live changes via manifest `handles:["sd.disk.mounted","sd.disk.unmounted"]` + `window.onBang_sd_disk_mounted/_unmounted`.

### `sd.display` — displays · `display`
- `sd.display.all` *(channel, default `[]`, poll-tunable)* — per-display info + brightness.
- `sd.display.changed` *(channel, delta, non-replayable)* — `{added, removed, changed}`.
- `forPoint(x, y) → display|null` *(sync)* · `forWindow(winObjOrId) → display|null|Promise<…>`.
- `setBrightness(value)` / `setBrightness(displayID, value)` / `setBrightness(value,{displayId}) → Promise` — 0..1; external via DDC/CI.
- `getBrightness(opts?) → Promise<number|null>` — `opts.displayId`; main display when omitted.
- `snapshot(opts?) → Promise<{dataURL,width,height}|null>` — `opts:{display?,region?{x,y,w,h},format?,quality?}`.

### `sd.displayLink` — vsync tick · `displayLink`
- `sd.displayLink` *(channel)* — `{ timestamp, frame, refreshRate }` per vsync (60/120Hz).

### `sd.events` — synthesize input + taps · `events`
- `type(text)` · `key(spec)` · `scroll(dx, dy)` · `click(x, y, button?)` (button default `"left"`) `→ Promise`.
- `setTapRects(callback, rects) → Promise` — gate a manifest eventtap by cursor rects: `null`=clear, `[]`=never-fire, `[{x,y,w,h}]`=fire only inside.
- `on(name, fn) → disposer` — register a handler for a manifest eventtap callback (replaces `window.onTap_<name>`).

### `sd.fs` — filesystem · `fs`
- `read(path, opts?) → Promise<string|null>` — `opts.encoding:"utf8"(default)|"base64"`. (`~` expands.)
- `stat(path)` · `list(dir, opts?)` (`opts.hidden`) `→ Promise`.
- `write(path, contents)` (atomic) · `mkdir(path)` (-p) · `delete(path)` (recursive) · `move(from, to)` (fails if dst exists) `→ Promise`.
- `watch(path, fn) → Promise<watchId|null>` — `fn` gets `{kind, path}`. · `unwatch(watchId) → Promise`.
- `xattr.get(path,name)` · `xattr.set(path,name,value)` (base64) · `xattr.list(path)` · `xattr.remove(path,name)` `→ Promise`.

### `sd.handlers` — generic slot registration
- `register(kind, name, fn) → disposer` — generic form of `sd.events.on` / `sd.hotkey.on` (kind e.g. `"Tap"`, `"Hotkey"`).

### `sd.host` — host info/load · `host`
- `sd.host.load` *(channel, poll-tunable)* — `{cpu{user,system,idle,total}, idleSeconds, memoryMB{used,free,wired}, memoryPressure, swap{totalMB,usedMB}, gpu{usagePercent}}`.
- `info() → Promise<{hostname, os{name,version,build}, locale, arch, cpuCount, ramMB}>`.
- `diskIO() → Promise<[{name, bytesRead, bytesWritten, opsRead, opsWritten, bytesReadPerSecond?, bytesWrittenPerSecond?}]>`.

### `sd.hotkey` — hotkeys · `hotkey`
- `bind(spec, fn, opts?) → Promise<id|null>` — Carbon hotkey; `opts:{mode?,apps?,excludeApps?}`. Supports `hyper`/`meh`.
- `unbind(id) → Promise`.
- `mode.enter(name)` · `mode.exit()` · `mode.current() → Promise<string>` — global modal keymaps.
- `on(name, fn) → disposer` — register a manifest-declared hotkey callback (replaces `window.onHotkey_<name>`).

### `sd.httpserver` — HTTP server · `httpserver`
- `serve(opts, callback) → Promise<{id, port, url, stop()}|null>` — `opts:{port?(0=auto),bindHost?("127.0.0.1"),bonjour?}`; `callback(req) → {status?,headers?,body?,bodyEncoding?("base64")}`.

### `sd.icons` — icons · `icons`
- `app(bundleId, opts?) → Promise<dataURL>` (`opts.size`, default 64pt) · `file(path, opts?) → Promise<dataURL>`.

### `sd.input` — keyboard layout + focused text · `input`
- `sd.input.layout` *(channel)* — current keyboard layout.
- `focusedText() → Promise<{text, selectedText, selectedRange{location,length}, caretRect{x,y,w,h}|null, role, subrole, value, pid, app}|null>`.
- `setSelectedText(value)` · `setSelectedRange(location, length) → Promise`.

### `sd.location` — location · `location`
- `sd.location` *(channel)* — `{lat, lon, accuracy, altitude?, heading?, speed?, timestamp}`. null until authorized + first fix.

### `sd.media` — now playing · `media`
- `sd.media.nowPlaying` *(channel)* — track metadata (Spotify/Music/Podcasts/browser).
- `command(name) → Promise` — `"play"|"pause"|"toggle"|"stop"|"next"|"previous"|"skipForward"|"skipBackward"`.

### `sd.menu` — popup menu · `menu`
- `popup(items) → Promise<pickedId|null>` — items `[{id,title,checked?,enabled?,separator?,submenu?}]` at cursor.

### `sd.menubar` — menu bar · `menubar` (+ `menubar.item` for `addItem`)
- `sd.menubar.observe` *(channel, poll-tunable, 2s)* — `[{owner,title,x,width,hidden}]` of visible status items.
- `sd.menubar.changed` *(channel, delta)* — `{added, removed, changed}`.
- `suppress()` / `restore() → Promise` — ref-counted system menubar visibility.
- `items() → Promise<[{owner,title,x,width,hidden}]>` — read-only AX walk.
- `addItem(spec) → Promise<MenubarItem|null>` *(perm `menubar.item`)* — `spec:{icon?{sfSymbol?,pngBase64?,template?}, title?, menu?[…], tooltip?, onClick?, onMenuPick?}`. Handle: `setTitle(s)` · `setIcon(spec)` · `setMenu(items)` · `setTooltip(s)` · `remove()` `→ Promise`; settable `onClick`/`onMenuPick`.

### `sd.mouse` — cursor channel · `mouse`
- `sd.mouse` *(channel)* — `{x, y, display:{id, frame{x,y,w,h}}|null}` (~30Hz).
- `warp(x, y) → Promise` — move cursor without click.

### `sd.net` — network · `net`
- `sd.net.wifi` *(channel)* · `sd.net.lan` *(channel)*.
- `sd.net.path` *(channel)* — `{status, interfaces[], isConstrained, isExpensive}` (NWPathMonitor).
- `sd.net.throughput` *(channel, poll-tunable, 1s)* — `{rxBps, txBps, rxBytes, txBytes}`.

### `sd.nlp` — NaturalLanguage · `nlp`
- `language(text) → Promise<langCode>` · `tokens(text, unit?) → Promise<string[]>` · `lemmas(text) → Promise<[{token,lemma,range}]>` · `similarity(a, b) → Promise<number>`.

### `sd.notify` — notifications · `notify`
- `show(spec) → Promise` — `spec:{title, body, subtitle?, sound?}`.

### `sd.overlay` — foreign-window overlay · `overlay`
- `attach(targetId, spec) → Promise<handle|null>` — `spec:{html?,css?,js?}` in a click-through panel tracking `targetId`'s bounds; `window.sd.target={x,y,w,h}` + `sd:target` event pushed each vsync. Handle: `setTarget(newTargetId)` · `eval(js)` · `detach()` `→ Promise`.

### `sd.pasteboard` — clipboard · `pasteboard`
- `sd.pasteboard.changed` *(channel)* — `{text, changeCount}`.
- `get()` · `set(value) → Promise`.

### `sd.privacy` — capture in-use · `privacy`
- `sd.privacy.observe` *(channel)* — `{screen:[], camera:[{device,id,inUse}], microphone:[…]}`; diff-pushed ~2s. (`screen` always `[]` in v1.)
- `recording() → Promise<{screen, camera, microphone}>` — one-shot; no TCC prompt.

### `sd.proc` — subprocess · `proc`
- `exec(cmd, args?, opts?) → Promise<{code, stdout, stderr}>` — `opts:{input?, timeout?(secs)}`.
- `stream(opts, callback) → Promise<{id, cancel()}|null>` — `opts:{cmd,args?,env?,cwd?}`; `callback({stream("stdout"|"stderr"|"exit"), chunk, code, signal?})`. `cancel()` SIGTERMs.

### `sd.screen` — current screen (sync) · none
- `sd.screen.current` — per-instance screen info injected before script runs (`window.__sd_screen`), read synchronously. null if unavailable.

### `sd.sensors` — internal sensors · `sensors`
- `sd.sensors` *(channel, poll-tunable, 2s)* — `{temperatures[{name,value,unit}], voltages[], currents[], fans[{name,rpm}]}` (Apple silicon).

### `sd.settings` — per-stack k/v · `settings`
- `get(key)` · `set(key, value)` · `delete(key)` · `all() → Promise` — JSON values, scoped to stack id.

### `sd.shortcuts` — Shortcuts · `shortcuts`
- `run(name, opts?) → Promise<{stdout, stderr, exitCode}>` — `opts:{input?, timeout?}`.

### `sd.sound` — sounds · `sound`
- `system(name) → Promise` (e.g. `"Glass"`) · `file(path) → Promise` (`~` expands) · `beep() → Promise`.

### `sd.spaces` — spaces · `spaces`
- `sd.spaces.all` *(channel, default `[]`)* — per-screen `{[uuid]:{spaces[], active, isFullscreen}}`.
- `windowSpaces(id) → Promise<number[]>` · `minimizedWindows(spaceID) → Promise<number[]>`.

### `sd.speech` — TTS/STT · `speech`
- `speak(text, opts?) → Promise` — `opts:{voice?,rate?(0..1),pitch?(0.5..2),volume?(0..1)}`.
- `stop(opts?) → Promise` — `opts.boundary:"immediate"(default)|"word"`.
- `voices() → Promise<[…]>` · `locales() → Promise<string[]>`.
- `listen(opts?) → { id, subscribe(fn)→unsub, stop() }` — STT; `fn({text, isFinal, segments, error})`; `opts:{locale?, requireOnDevice?}`. Mic + Speech TCC.
- `listen.cancel() → Promise`.

### `sd.spotlight` — Spotlight · `spotlight`
- `find(opts) → Promise<[attrDict]>` — `opts:{predicate(NSPredicate str), scopes?, attributes?, limit?}`.
- `subscribe(opts) → { id, subscribe(fn)→unsub, stop() }` — live; `fn` gets the full result-set each index update.

### `sd.sqlite` — SQLite · `sqlite`
- `open(path, opts?) → Promise<db|null>` — `opts.mode:"readwrite"(default)`; default path under `~/stackd/stacks/<id>/data/`. db: `exec(sql)` · `query(sql, params?) → Promise<rows>` · `close()`; props `handle`, `path`. (FTS4/FTS5 available.)

### `sd.thumbnails` — QuickLook · `thumbnails`
- `generate(opts) → Promise<{dataURL,width,height,type}|null>` — `opts:{path, width?, height?, scale?, representation?, format?, quality?, timeoutSeconds?}`.

### `sd.timer` — reload-safe scheduling · none
- `timeout(fn, ms) → disposer` · `interval(fn, ms) → disposer` · `debounce(fn, ms) → callable(+.cancel())` · `throttle(fn, ms) → callable`. All auto-clear on page unload. (For UI timing only — not for polling macOS state; see [Lifecycle & rules](../concepts/lifecycle-and-rules.md#stacks-dont-poll).)

### `sd.touchdevice` — trackpad frames · `touchdevice`
- `sd.touchdevice` *(channel, ~30Hz)* — `{timestamp, frame, touches:[{identifier, state, x, y, vx, vy, angle, size, pressure, majorAxis, minorAxis}]}`. x/y normalized 0..1 (bottom-left origin). Zero CPU when unsubscribed.

### `sd.tpl` — tagged template · none
- ``sd.tpl`…${signal|value}…` → Element | DocumentFragment`` — see [Template engine → sd.tpl](template-engine.md#sdtpl--tagged-template).

### `sd.update` — software updates · `update`
- `list(opts?) → Promise<[{label,title?,version?,sizeKiB?,recommended,requiresRestart}]>` — `opts:{force?, ttlSeconds?}`. Cached ~6h.

### `sd.urlhandler` — URL schemes · `urlhandler`
- `register(scheme, fn) → Promise<{id, unregister()}|null>` — `fn(event{url,scheme,host,path,query,fragment})`. (Routes only when bundled with `CFBundleURLTypes`.)

### `sd.usb` — USB devices · `usb`
- `sd.usb` *(channel, default `[]`)* — `[{vendorID,productID,vendorName?,productName?,serialNumber?,locationID}]`.

### `sd.util` — pure helpers · none
- `debounce(fn, ms) → callable(+.cancel())` · `throttle(fn, ms) → callable` (delegate to `sd.timer`).

### `sd.vision` — Vision · `vision`
- `ocr(opts) → Promise<{observations:[{text,confidence,boundingBox{x,y,w,h}}]}>` — `opts:{image, languages?, recognitionLevel?}`. boundingBox normalized top-left.
- `faces(opts) → Promise<{observations:[{boundingBox,confidence,roll?,yaw?,pitch?}]}>`.
- `featurePrint(opts) → Promise<{print(base64),elementCount,elementType}>` · `featurePrintDistance(a, b) → Promise<{distance}>`.
- `subjectMask(opts) → Promise<{dataURL,width,height}|null>` — bg removed; null on macOS 13 / no subject.
- `bodyPose(opts) → Promise<{bodies:[{joints{<name>:{x,y,confidence}}, confidence}]}>`.

### `sd.window` — THIS stack's panel · self-scoped
Operates on the stack's own NSPanel; no separate permission.
- `invoke()` / `dismiss() → Promise` — for `invocable:true` stacks (show+focus / hide+restore).
- `setAlpha(value) → Promise` — fade whole panel 0..1.
- `setFrame({x, y, w?, h?}) → Promise` — reposition/resize at runtime (top-left origin).
- `setClickThrough(value) → Promise`.
- `configure(spec) → Promise` — `spec:{alpha?, clickThrough?, frame?{x,y,w,h}}` aggregator.

### `sd.windows` — all windows · `windows`
**Channels:**
- `sd.windows.focused` *(channel)* — `{id,pid,app,bundleId,title,frame,display?,space?}`.
- `sd.windows.all` *(channel, default `[]`)* — `[{id,app,pid,title,onscreen,addressable,isStandard,isMinimized,frame,display?}]`.
- `sd.windows.changed` *(channel, delta)* — `{added, removed, changed}`.
- `sd.windows.focusedChanged` *(channel)* · `sd.windows.titleChanged` *(channel)*.
- Lifecycle bang-channels (require manifest `handles`): `created, destroyed, moved, resized, minimized, deminimized` — `.subscribe(fn)` with bang payloads.

**Methods** (no id = AX focused window of frontmost app; numeric id = specific CGWindowID):
- `setFrame(frame)` or `setFrame(id, frame) → Promise`.
- `setFrameProbed(id, frame) → Promise<{ok, actual{x,y,w,h}|null}>`.
- `minimize([id,] value?)` · `fullscreen([id,] value?)` · `raise([id])` · `focus(id)` · `close(id)` `→ Promise`.
- `frame(id) → Promise<{x,y,w,h}>` · `cornerHints(id) → Promise<{toolbarPresent,role,subrole}>`.
- `buttonFrames(id) → Promise<{close,zoom,minimize}|null>` (traffic-light rects).
- `info(id) → Promise<{frame,title,role,subrole,isMinimized,isFullscreen,isMain,isStandard,hasToolbar,cornerHints}|null>`.
- `title(id)` · `role(id)` · `subrole(id)` · `isMinimized(id)` · `isFullscreen(id)` · `hasToolbar(id)` · `isStandard(id)` `→ Promise`.
- `tabs(id) → Promise<[{title,selected}]|null>` · `focusTab(id, index) → Promise`.
- `snapshot(id, opts?) → Promise<{dataURL,width,height}|null>` — `opts:{format?,quality?(0.85)}`. SPI capture (works for hidden/minimized).
- `batch(fn) → Promise<boolean>` — atomic multi-window setFrame transaction (queued + committed on one compositor flip).

---

## Notes

- **`sd.bang` is ungated** — the one author-facing primitive with no permission string.
- **`sd.screen`, `sd.bind`, `sd.tpl`, `sd.timer`, `sd.util`** require no permission and do no IPC.
- **`menubar.item`** is a composite permission — declare it explicitly; it isn't inferred ([Permissions](../concepts/permissions.md)).
- Window-lifecycle bang channels have **no `{{ }}` template surface**; reach them via `.subscribe` / `onBang_*`, gated by `windows`.

## See also

- [The reactive model](../concepts/reactive-model.md) · [Template engine](template-engine.md) · [Manifest reference](manifest.md) · [Permissions](../concepts/permissions.md)
