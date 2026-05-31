// sd://runtime/api.js
// The `sd.*` namespace exposed to every stack.

function signal(initial) {
  let value = initial;
  const subs = new Set();
  return {
    get value() { return value; },
    set value(next) {
      if (Object.is(next, value)) return;
      value = next;
      for (const s of subs) s(value);
    },
    subscribe(fn) {
      subs.add(fn);
      fn(value);
      return () => subs.delete(fn);
    },
    peek() { return value; },
  };
}

const channels = Object.create(null);
function channel(name, initial = null) {
  if (!channels[name]) channels[name] = signal(initial);
  return channels[name];
}

// Native pushes via webView.evaluateJavaScript("window.__sd_push(...)").
window.__sd_push = (name, payload) => {
  channel(name).value = payload;
};

// Request/response (used by sd.defaults.read). Native fires window.__sd_response(id, value).
const pending = new Map();
let nextRequestId = 1;
window.__sd_response = (id, value) => {
  const resolve = pending.get(id);
  if (resolve) { pending.delete(id); resolve(value); }
};
// Filesystem watch dispatch. Native fires window.__sd_fs_event(watchId, [{kind, path}, ...])
// after sd.fs.watch returns a watchId.
const fsHandlers = new Map();
window.__sd_fs_event = (watchId, events) => {
  const fn = fsHandlers.get(watchId);
  if (fn && Array.isArray(events)) {
    for (const ev of events) fn(ev);
  }
};
// NSStatusItem callbacks routed by mint id. Populated by sd.menubar.addItem,
// drained on item.remove(). Native fires:
//   window.__sd_menubar_event(itemId, "click", null)
//   window.__sd_menubar_event(itemId, "pick",  pickedItemIdString)
const menubarHandlers = new Map();
window.__sd_menubar_event = (itemId, type, payload) => {
  const cb = menubarHandlers.get(itemId);
  if (!cb) return;
  if (type === "click" && cb.onClick)    cb.onClick();
  if (type === "pick"  && cb.onMenuPick) cb.onMenuPick(payload);
};
// JS-bound Carbon hotkeys: id → callback fn. Native mints the id on bind,
// fires window.__sd_hotkey_fire(id) on Carbon callback. Unbind removes here
// and on the Swift side. Stack unload drops the map naturally with the page.
const hotkeyHandlers = new Map();
window.__sd_hotkey_fire = (id) => {
  const fn = hotkeyHandlers.get(id);
  if (fn) fn();
};
// DN callbacks routed by mint id. Populated by sd.broadcasts.observe.
const broadcastHandlers = new Map();
window.__sd_broadcast_fire = (id, payload) => {
  const fn = broadcastHandlers.get(id);
  if (fn) fn(payload);
};
// HTTP servers: serverId → { routes: { "POST /events": fn }, ... }.
// Native fires window.__sd_http_request(serverId, reqId, req) on every match.
// JS resolves with sd.httpserver.respond(reqId, response).
const httpServers = new Map();
window.__sd_http_request = async (serverId, reqId, req) => {
  const server = httpServers.get(serverId);
  if (!server) {
    await request({ type: "httpserver.respond", reqId, status: 503, headers: {}, body: "no server" });
    return;
  }
  const key = `${req.method} ${req.path}`;
  const handler = server.routes[key] || server.routes[`* ${req.path}`];
  if (!handler) {
    await request({ type: "httpserver.respond", reqId, status: 404, headers: {}, body: "no route" });
    return;
  }
  let resp;
  try { resp = await handler(req); }
  catch (e) { resp = { status: 500, body: String(e) }; }
  resp = resp || {};
  await request({
    type: "httpserver.respond",
    reqId,
    status:  resp.status  || 200,
    headers: resp.headers || {},
    body:    resp.body == null ? "" : String(resp.body)
  });
};
function request(payload) {
  const requestId = nextRequestId++;
  return new Promise((resolve) => {
    pending.set(requestId, resolve);
    try {
      window.webkit.messageHandlers.sd.postMessage({ ...payload, requestId });
    } catch (e) {
      pending.delete(requestId);
      resolve(null);
    }
  });
}

export const sd = {
  // Per-instance screen info, injected before this script runs (see Bridge.swift).
  // Read .current synchronously — items like spacenum + brightness need to
  // know which screen they're rendered on without an async round-trip.
  screen:     { current: window.__sd_screen || null },
  battery:    channel("battery"),
  mouse:      Object.assign(channel("mouse"), {
    // Move the cursor without clicking. Top-left origin (same coord space
    // as sd.windows.focused().frame). Pairs with the subscribe channel:
    //   sd.mouse.subscribe(pt => /* read .x .y */);
    //   sd.mouse.warp(100, 200);
    warp(x, y) { return request({ type: "mouse.warp", x, y }); }
  }),
  appearance: channel("appearance"),
  app:        { frontmost: channel("frontApp") },
  windows:    {
    focused: channel("focusedWindow"),
    all:     channel("windowsAll"),
    // Actions with no id operate on the AX focused window of the frontmost app.
    // Pass an id (CGWindowID from sd.windows.all / sd.windows.focused) to
    // target a specific window via the _AXUIElementGetWindow SPI.
    setFrame(arg1, arg2) {
      if (typeof arg1 === "number") {
        const f = arg2 || {};
        return request({ type: "windows.byId.setFrame", id: arg1, x: f.x, y: f.y, w: f.w, h: f.h });
      }
      const f = arg1 || {};
      return request({ type: "windows.setFrame", x: f.x, y: f.y, w: f.w, h: f.h });
    },
    minimize(arg1, arg2) {
      if (typeof arg1 === "number") {
        return request({ type: "windows.byId.minimize", id: arg1, value: arg2 === undefined ? true : !!arg2 });
      }
      return request({ type: "windows.minimize", value: arg1 === undefined ? true : !!arg1 });
    },
    fullscreen(arg1, arg2) {
      if (typeof arg1 === "number") {
        return request({ type: "windows.byId.fullscreen", id: arg1, value: arg2 === undefined ? true : !!arg2 });
      }
      return request({ type: "windows.fullscreen", value: arg1 === undefined ? true : !!arg1 });
    },
    raise(id) {
      if (typeof id === "number") return request({ type: "windows.byId.raise", id });
      return request({ type: "windows.raise" });
    },
    focus(id)  { return request({ type: "windows.byId.focus", id }); },
    close(id)  { return request({ type: "windows.byId.close", id }); },
    frame(id)  { return request({ type: "windows.byId.frame", id }); }
  },
  input:      { layout:    channel("inputLayout") },
  net:        {
    wifi: channel("netWifi"),
    lan:  channel("netLan")
  },
  defaults: {
    read(bundleId, key) {
      return request({ type: "defaults.read", bundleId, key });
    }
  },
  audio: {
    output:     channel("audioOutput"),
    setVolume(v) { return request({ type: "audio.setVolume", value: v }); },
    setMuted(m)  { return request({ type: "audio.setMuted",  value: !!m }); }
  },
  display: {
    all:        channel("displays"),
    setBrightness(displayID, value) {
      return request({ type: "display.setBrightness", displayID, value });
    },
    // Single-frame pixel capture. Returns { dataURL, width, height } or null.
    //   await sd.display.snapshot()                       // main display, PNG
    //   await sd.display.snapshot({ display: id })        // by CGDirectDisplayID
    //   await sd.display.snapshot({ region: {x,y,w,h} })  // point-space crop on main
    //   await sd.display.snapshot({ format: "jpeg", quality: 0.7 })
    // dataURL is droppable directly into <img src>. width/height are pixels.
    snapshot(opts) {
      const o = opts || {};
      return request({
        type: "display.snapshot",
        displayID: o.display,
        region: o.region,
        format: o.format || "png",
        quality: o.quality
      });
    }
  },
  menubar: {
    // Reference-counted system menu-bar visibility.
    // Multiple stacks can suppress; the bar reappears only once every
    // suppressor has called restore().
    suppress() { return request({ type: "menubar.suppress" }); },
    restore()  { return request({ type: "menubar.restore"  }); },

    // Add an NSStatusItem to the system menu bar. Requires "menubar.item"
    // permission (distinct from "menubar", which gates suppress/restore).
    //
    // spec: {
    //   icon?:    { sfSymbol?, pngBase64?, template? }   // template defaults true
    //   title?:   string
    //   menu?:    [{ id, title, separator?, submenu?, enabled?, checked? }]
    //   tooltip?: string
    //   onClick?: () => void                             // ignored if `menu` set
    //   onMenuPick?: (id: string) => void                // fires with menu-item.id
    // }
    //
    // Returns a Promise<MenubarItem | null>. The handle's lifetime is bound
    // to the stack — unload removes the item automatically.
    async addItem(spec) {
      const { onClick, onMenuPick, icon, title, menu, tooltip } = spec || {};
      const id = await request({
        type: "menubar.addItem",
        icon, title, menu, tooltip
      });
      if (id == null || id === false) return null;
      menubarHandlers.set(id, { onClick, onMenuPick });
      return {
        id,
        setTitle(s)       { return request({ type: "menubar.item.setTitle",   id, title: s }); },
        setIcon(iconSpec) { return request({ type: "menubar.item.setIcon",    id, icon: iconSpec }); },
        setMenu(items)    { return request({ type: "menubar.item.setMenu",    id, items }); },
        setTooltip(s)     { return request({ type: "menubar.item.setTooltip", id, tooltip: s }); },
        remove() {
          menubarHandlers.delete(id);
          return request({ type: "menubar.item.remove", id });
        },
        // Re-assign callbacks after construction (e.g. once a dynamic menu
        // is wired up). Map stays internal.
        set onClick(fn)    { const e = menubarHandlers.get(id) || {}; e.onClick    = fn; menubarHandlers.set(id, e); },
        set onMenuPick(fn) { const e = menubarHandlers.get(id) || {}; e.onMenuPick = fn; menubarHandlers.set(id, e); }
      };
    }
  },
  media: {
    // Covers Spotify / Apple Music / Podcasts / browser audio.
    // command(name) — "play" | "pause" | "toggle" | "stop" | "next" |
    //                 "previous" | "skipForward" | "skipBackward"
    nowPlaying: channel("media"),
    command(name) { return request({ type: "media.command", name }); }
  },
  settings: {
    // Per-stack k/v persistence, scoped to this stack's id.
    // Stored values must be JSON-compatible.
    get(key)        { return request({ type: "settings.get",    key }); },
    set(key, value) { return request({ type: "settings.set",    key, value }); },
    delete(key)     { return request({ type: "settings.delete", key }); },
    all()           { return request({ type: "settings.all" }); }
  },
  fs: {
    // Imperative — paths support ~ expansion.
    read(path)      { return request({ type: "fs.read", path }); },
    stat(path)      { return request({ type: "fs.stat", path }); },
    list(dir, opts) { return request({ type: "fs.list", dir, hidden: !!(opts && opts.hidden) }); },
    // Write is atomic (temp-file then rename) so half-written contents never
    // appear to readers or to FSEvents-driven reloaders. mkdir is mkdir -p.
    // delete is recursive. move is rename (fails if dst exists).
    write(path, contents) { return request({ type: "fs.write", path, contents: String(contents ?? "") }); },
    mkdir(path)           { return request({ type: "fs.mkdir", path }); },
    delete(path)          { return request({ type: "fs.delete", path }); },
    move(from, to)        { return request({ type: "fs.move", from, to }); },
    // Push — returns a watchId you pass to unwatch(). Callback receives
    // an array of { kind, path } events (coalesced by FSEvents at ~100ms).
    async watch(path, fn) {
      const watchId = nextRequestId++;
      fsHandlers.set(watchId, fn);
      const ok = await request({ type: "fs.watch.start", path, watchId });
      if (!ok) { fsHandlers.delete(watchId); return null; }
      return watchId;
    },
    async unwatch(watchId) {
      fsHandlers.delete(watchId);
      return request({ type: "fs.watch.stop", watchId });
    }
  },
  pasteboard: {
    changed:   channel("pasteboard"),                       // signal: {text, changeCount}
    get()      { return request({ type: "pasteboard.get" }); },
    set(value) { return request({ type: "pasteboard.set", value }); }
  },
  proc: {
    // exec(cmd, args, opts?) → Promise<{code, stdout, stderr}>
    // opts: { input?: string, timeout?: seconds }
    exec(cmd, args, opts) {
      return request({
        type: "proc.exec",
        cmd, args: args || [],
        input: opts && opts.input,
        timeout: opts && opts.timeout
      });
    }
  },
  // AppleScript / JXA runner — faster than spawning /usr/bin/osascript for
  // every call (NSAppleScript runs in-process). Use for: scripting other apps
  // via Apple Events, querying System Events for window/UI info, anything
  // `tell application X to ...` shaped.
  //   const r = await sd.applescript.run(`return 1 + 1`);
  //   const r = await sd.applescript.run(`return Math.PI`, { language: "javascript" });
  // Returns: { ok: boolean, result: string, error?: string }.
  applescript: {
    run(source, opts) {
      return request({
        type: "applescript.run",
        source: String(source ?? ""),
        language: (opts && opts.language) || "applescript",
        timeout: (opts && opts.timeout) || 10
      });
    }
  },
  events: {
    // Synthesize input. Note: scroll/click also fire your own eventtap
    // handlers if you have any registered. Use with care.
    type(text)            { return request({ type: "events.type", value: text }); },
    key(spec)             { return request({ type: "events.key",  spec }); },
    scroll(dx, dy)        { return request({ type: "events.scroll", dx, dy }); },
    click(x, y, button)   { return request({ type: "events.click", x, y, button: button || "left" }); }
  },
  // Cursor — warp / read. Top-left global coords by default (same convention
  // as sd.mouse). Pass `display` (CGDirectDisplayID from sd.display.all) to
  // interpret coords as display-local.
  //   await sd.cursor.setPosition({ x: 100, y: 200 });
  //   await sd.cursor.setPosition({ x: 0, y: 0, display: displays[1].displayID });
  //   const p = await sd.cursor.position();   // { x, y } — top-left global
  // Consumers: EdgeHopper (wrap cursor to opposite edge on punch-through);
  // CloudPad (in-process replacement for the JXA CGWarpMouseCursorPosition
  // shim under continuous pointer-mode moves).
  cursor: {
    setPosition(p) {
      const o = p || {};
      return request({ type: "cursor.setPosition", x: o.x, y: o.y, display: o.display });
    },
    position() { return request({ type: "cursor.position" }); }
  },
  apps: {
    // running: signal<[{pid, bundleId, name, active, hidden, launchedAt?}]>
    // — fires on launch/quit/hide/unhide/activate.
    running: channel("apps"),
    // Transition deltas: { added: [...], removed: [...], changed: [...] }.
    // Fires only when something actually changed (not the initial full list
    // — for that, subscribe to .running). Consumers that only care about
    // launches/quits don't have to diff the full list themselves.
    changed: channel("appsChanged"),
    launch(bundleId)          { return request({ type: "apps.launch", bundleId }); },
    focus(bundleId)           { return request({ type: "apps.focus",  bundleId }); },
    kill(bundleId, force)     { return request({ type: "apps.kill",   bundleId, force: !!force }); },
    hide(bundleId)            { return request({ type: "apps.hide",   bundleId }); }
  },
  icons: {
    // Returns a `data:image/png;base64,...` URL you can drop into <img src="">.
    // Default size 64pt. Cached by the browser.
    app(bundleId, opts) { return request({ type: "icons.app",  bundleId, size: (opts && opts.size) || 64 }); },
    file(path, opts)    { return request({ type: "icons.file", path,     size: (opts && opts.size) || 64 }); }
  },
  ax: {
    // Back-compat: focused UI element of the frontmost app as a dict
    // { app, pid, role, roleDescription?, value?, selectedText?,
    //   selectedRange?: {location, length}, caretBounds?: {x,y,w,h} }
    focused() { return request({ type: "ax.focused" }); },

    // Generic axuielement-style API. Element handles are opaque integers
    // owned by this stack's bridge. Every read that returns an AXUIElement
    // (or array of them) mints a *new* handle — release with .release(h)
    // or .releaseAll() to keep the store from growing without bound.
    //
    // Marshalling:
    //   AXValue<CGRect>  ↔ {x,y,w,h}    AXValue<CGPoint>  ↔ {x,y}
    //   AXValue<CGSize>  ↔ {w,h}        AXValue<CFRange>  ↔ {location,length}
    //   AXUIElement      → number       arrays/dicts recurse
    application(pid)                  { return request({ type: "ax.application", pid }); },
    system()                          { return request({ type: "ax.system" }); },
    systemElementAtPosition(x, y)     { return request({ type: "ax.systemElementAtPosition", x, y }); },
    focusedElement()                  { return request({ type: "ax.focusedElement" }); },
    attributeNames(handle)            { return request({ type: "ax.attributeNames", handle }); },
    attribute(handle, name)           { return request({ type: "ax.attribute", handle, name }); },
    attributes(handle)                { return request({ type: "ax.attributes", handle }); },
    parameterizedAttributeNames(handle) { return request({ type: "ax.parameterizedAttributeNames", handle }); },
    parameterizedAttribute(handle, name, param) {
      return request({ type: "ax.parameterizedAttribute", handle, name, param });
    },
    actionNames(handle)               { return request({ type: "ax.actionNames", handle }); },
    isAttributeSettable(handle, name) { return request({ type: "ax.isAttributeSettable", handle, name }); },
    setAttribute(handle, name, value) { return request({ type: "ax.setAttribute", handle, name, value }); },
    performAction(handle, action)     { return request({ type: "ax.performAction", handle, action }); },
    children(handle)                  { return request({ type: "ax.children", handle }); },
    parent(handle)                    { return request({ type: "ax.parent", handle }); },
    role(handle)                      { return request({ type: "ax.role", handle }); },
    release(handle)                   { return request({ type: "ax.release", handle }); },
    releaseAll()                      { return request({ type: "ax.releaseAll" }); }
    // observe(...) deferred — see README. Stacks that need AX notifications
    // can poll via sd.app.frontmost + a setTimeout for now.
  },
  window: {
    // Only meaningful for stacks declared with `invocable: true` in their
    // manifest. Such stacks start hidden; .invoke() shows + takes keyboard
    // focus; .dismiss() hides + returns focus to the previous app.
    invoke()  { return request({ type: "window.invoke" }); },
    dismiss() { return request({ type: "window.dismiss" }); }
  },
  hotkey: {
    // Dynamically bind a Carbon hotkey from JS. Equivalent to the manifest
    // `hotkeys` block but works after the stack starts — for transient chords
    // like a Palette in verb mode or a chooser's number keys.
    //   const h = await sd.hotkey.bind("ctrl+alt+l", () => doThing());
    //   ...later...
    //   await sd.hotkey.unbind(h);
    // Options (skhd parity):
    //   { mode: "command" }            // only fires while sd.hotkey.mode.current() === "command"
    //   { apps: ["com.apple.Safari"] } // only fires when Safari is frontmost; "*" matches any
    // Returns null if the spec doesn't parse. Per-stack: unload cancels all.
    async bind(spec, fn, opts = {}) {
      const id = await request({
        type: "hotkey.bind",
        spec,
        mode: opts.mode ?? null,
        apps: opts.apps ?? null
      });
      if (id == null || id === false) return null;
      hotkeyHandlers.set(id, fn);
      return id;
    },
    async unbind(id) {
      hotkeyHandlers.delete(id);
      return request({ type: "hotkey.unbind", id });
    },
    // Modal keymaps. While a non-default mode is active, only bindings
    // declared for that mode fire; bindings without a mode are always-on.
    // Mode is GLOBAL across all stacks — entering "command" suppresses every
    // other stack's default-mode hotkeys too, matching skhd's model.
    //   await sd.hotkey.mode.enter("window");
    //   await sd.hotkey.mode.exit();   // back to "default"
    //   await sd.hotkey.mode.current(); // → "default" | "window" | ...
    mode: {
      enter(name)  { return request({ type: "hotkey.mode.enter", name }); },
      exit()       { return request({ type: "hotkey.mode.exit" }); },
      current()    { return request({ type: "hotkey.mode.current" }); }
    }
  },
  // Generic NSDistributedNotificationCenter observer. The same machinery
  // Caffeinate uses internally (com.apple.screenIsLocked, etc.) but exposed
  // to any stack. Permission: "broadcasts".
  //   const id = await sd.broadcasts.observe(
  //     "com.apple.screenIsLocked",
  //     (payload) => console.log("locked at", payload));
  //   ...later...
  //   await sd.broadcasts.unobserve(id);
  broadcasts: {
    async observe(name, fn) {
      const id = await request({ type: "broadcasts.observe", name });
      if (id == null || id === false) return null;
      broadcastHandlers.set(id, fn);
      return id;
    },
    async unobserve(id) {
      broadcastHandlers.delete(id);
      return request({ type: "broadcasts.unobserve", id });
    }
  },
  // Long-running HTTP server. Loopback-only by default; pass
  // bindHost: "0.0.0.0" to expose on the LAN. Routes are method+path keys
  // pointing to async handlers that return { status?, headers?, body? }.
  // Static assets ride on assetsDir (relative paths under it served as-is).
  //   const srv = await sd.httpserver.serve({
  //     port: 7373,
  //     routes: {
  //       "GET /hello":  async (req) => ({ body: "hello" }),
  //       "POST /event": async (req) => { handle(req.body); return { status: 204 }; }
  //     },
  //     assetsDir: "~/stackd/stacks/cloudpad/public",  // optional
  //     bonjour: { type: "_http._tcp.", name: "cloudpad" } // optional
  //   });
  //   ...later...
  //   await srv.stop();
  // Consumers: CloudPad (serves snapshot + bang surface to phones on the LAN);
  // any webhook receiver or local API dashboard stack.
  httpserver: {
    async serve(opts) {
      const o = opts || {};
      const routes = o.routes || {};
      const id = await request({
        type: "httpserver.serve",
        port: o.port || 0,
        bindHost: o.bindHost || "127.0.0.1",
        assetsDir: o.assetsDir,
        routes: Object.keys(routes),
        bonjour: o.bonjour
      });
      if (id == null) return null;
      httpServers.set(id, { routes });
      return {
        id,
        port: o.port,
        url: `http://${o.bindHost === "0.0.0.0" ? "localhost" : (o.bindHost || "127.0.0.1")}:${o.port}`,
        async stop() {
          httpServers.delete(id);
          return request({ type: "httpserver.stop", id });
        }
      };
    }
  },
  // Fire a bang to every stack whose manifest `handles` array contains `name`.
  // Returns the count of stacks that received it. Same dispatch as
  // system-fired bangs — JS handlers register via
  // `window.onBang_<sanitized_name> = (detail) => { ... }`.
  //
  // System-fired window bangs (see Sources/DataSources/WindowEvents.swift +
  // Sources/DataSources/Windows.swift):
  //   sd.window.created        { id, pid, app, title, frame } — CGS + 1Hz poll
  //   sd.window.destroyed      { id }                         — CGS + 1Hz poll
  //   sd.window.titleChanged   { id, app, title, oldTitle, frame, pid } — 1Hz poll
  //   sd.window.moved          { id, frame }                  — CGS (high rate during drag)
  //   sd.window.resized        { id, frame }                  — CGS (high rate during resize)
  //   sd.window.minimized      { id }                         — CGS
  //   sd.window.deminimized    { id }                         — CGS
  //   sd.window.reordered      { id }                         — CGS (z-order change)
  //   sd.window.focusedByMouse { }                            — CGS (frontmost-app change)
  bang(name, detail) { return request({ type: "bang", name, detail: detail || {} }); },
  // Per-screen Spaces info via SkyLight private SPI:
  //   { [screenUUID]: { spaces: [id, ...], active: id|null, isFullscreen: bool } }
  // Fires on NSWorkspaceActiveSpaceDidChangeNotification.
  // Banner notifications via macOS Notification Center. Fire-and-forget.
  // Attributed to "Script Editor" (osascript) until stackd ships as a
  // bundled .app — click handling deferred until then.
  //   await sd.notify.show({ title: "AppTimeout", body: "Slack closes in 1 min" });
  notify: {
    show(spec) {
      return request({
        type: "notify.show",
        title: (spec && spec.title) || "",
        body: (spec && spec.body) || "",
        subtitle: spec && spec.subtitle,
        sound: spec && spec.sound
      });
    }
  },
  // Play short sounds via NSSound. Fire-and-forget; no completion callback.
  //   sd.sound.system("Glass")           // /System/Library/Sounds/Glass.aiff
  //   sd.sound.file("~/Music/ding.mp3")  // arbitrary file (~ expanded)
  //   sd.sound.beep()                    // NSBeep
  sound: {
    system(name) { return request({ type: "sound.system", name }); },
    file(path)   { return request({ type: "sound.file",   path }); },
    beep()       { return request({ type: "sound.beep" }); }
  },
  // System sleep / screen-lock signal: { sleeping, locked }.
  // Sleeping flips true between willSleep and didWake; locked flips true
  // between com.apple.screenIs{Locked,Unlocked} distributed notifications.
  // Use for "don't accumulate time while screen is off" (AppTimeout),
  // "stop drawing while asleep" (TimeTrail), etc.
  caffeinate: channel("caffeinate"),
  // Vsync-locked frame tick. Refresh rate matches the display (60 Hz on
  // standard, 120 Hz on ProMotion). Cheaper + smoother than rAF inside a
  // heavy WebView, and aligned to the compositor's flip cadence — required
  // by sd.overlay's CG context flushes.
  //   sd.displayLink.subscribe(({ timestamp, frame, refreshRate }) => { ... })
  displayLink: channel("displayLink"),
  // System info (one-shot) + load signal (polled 2s):
  //   await sd.host.info()  → { hostname, os: {name,version,build}, locale,
  //                              arch, cpuCount, ramMB }
  //   sd.host.load          → { cpu: {user,system,idle,total},  // 0-1 fractions
  //                              idleSeconds,                    // since last HID
  //                              memoryMB: {used,free,wired} }
  // First load tick fires ~2s after subscribe (CPU fractions need a prior
  // sample to diff against). idleSeconds resets to ~0 the instant the user
  // moves the mouse or types.
  host: {
    info() { return request({ type: "host.info" }); },
    load:  channel("hostLoad")
  },
  // Mac internal sensors via IOHIDEventSystem (Apple silicon: per-die temps,
  // per-rail voltage/current, fan RPM). Polled at 2s. Intel SMC sensors deferred.
  //   sd.sensors → { temperatures: [{name,value,unit}, ...], voltages: [...],
  //                  currents: [...], fans: [{name, rpm}, ...] }
  sensors: channel("sensors"),
  // Raw per-finger trackpad frames via MultitouchSupport (private framework).
  // ~30 Hz coalesced from the underlying ~80 Hz callback. Frames arrive
  // BELOW the layer where AppKit recognizes swipe/pinch/rotate — use this
  // (not sd.gesture) when you want raw fingers with stable identity.
  //   sd.touchdevice → { timestamp, frame, touches: [
  //     { identifier, state, x, y, vx, vy, angle, size, pressure,
  //       majorAxis, minorAxis }, ...] }
  // state values: "began" | "stationary" | "moved" | "ended" | "cancelled" | "lifted".
  // x/y are 0..1 trackpad-normalized (origin bottom-left). Empty touches[]
  // = all fingers lifted (the "release" edge consumers' state machines need).
  // Consumers: TTTaps multi-finger recognizer, trackpad heatmap, custom
  // pinch-curve overlay. Cost: zero CPU when no stack subscribes.
  touchdevice: channel("touchdevice"),
  // Apple's NaturalLanguage framework — language ID, tokenization, lemmas,
  // sentence similarity (via NLEmbedding cosine). All synchronous. Useful for
  // Palette command ranking, smart-paste rewrites, "did you mean X" hints.
  //   await sd.nlp.language("Hola mundo")            // → "es"
  //   await sd.nlp.tokens("The quick brown fox")     // → ["The","quick",...]
  //   await sd.nlp.lemmas("running dogs")            // → [{token,lemma,range},...]
  //   await sd.nlp.similarity("open", "launch")      // → 0.72
  // similarity() returns 0 when the embedding model for the detected language
  // isn't on-device (English ships by default; others download on demand).
  nlp: {
    language(text)     { return request({ type: "nlp.language",   text: String(text ?? "") }); },
    tokens(text, unit) { return request({ type: "nlp.tokens",     text: String(text ?? ""), unit }); },
    lemmas(text)       { return request({ type: "nlp.lemmas",     text: String(text ?? "") }); },
    similarity(a, b)   { return request({ type: "nlp.similarity", a: String(a ?? ""), b: String(b ?? "") }); }
  },
  // Embedded SQLite (libsqlite3). Minimal wrapper: open / exec / query / close.
  // Default path lands under ~/stackd/stacks/<id>/data/ — absolute paths
  // and ~ paths pass through. FTS4 and FTS5 are compiled into the system
  // libsqlite3 so `CREATE VIRTUAL TABLE ... USING fts5(...)` works.
  //   const db = await sd.sqlite.open("notes.db");
  //   await db.exec("CREATE TABLE IF NOT EXISTS k(v INTEGER)");
  //   await db.exec("INSERT INTO k(v) VALUES (42)");
  //   const r = await db.query("SELECT v FROM k WHERE v > ?", [10]);
  //   await db.close();
  // Consumers: DigUp (FTS-indexed OCR snapshots); persistence-heavy stacks
  // (notes app, quick-search index, history-of-clipboard) where settings.set
  // would be a denormalized mess.
  sqlite: {
    async open(path, opts) {
      const o = opts || {};
      const result = await request({
        type: "sqlite.open",
        path: String(path ?? ""),
        mode: o.mode || "readwrite"
      });
      if (!result || !result.handle) return null;
      const handle = result.handle;
      return {
        handle,
        path: result.path,
        exec(sql)              { return request({ type: "sqlite.exec",  handle, sql: String(sql ?? "") }); },
        query(sql, params)     { return request({ type: "sqlite.query", handle, sql: String(sql ?? ""), params: params || [] }); },
        close()                { return request({ type: "sqlite.close", handle }); }
      };
    }
  },
  // Apple's Vision framework. OCR via VNRecognizeTextRequest.
  //   await sd.vision.ocr({ image: dataURL })
  //   await sd.vision.ocr({ image: "/path/to/img.png", languages: ["en"], recognitionLevel: "fast" })
  // Returns { observations: [{ text, confidence, boundingBox: {x,y,w,h} }] }
  // where boundingBox is normalized (0..1) in web-style top-left origin so
  // overlays render directly on top of an <img> with no flip math.
  // Consumers: DigUp (screenshot → OCR → FTS index); ad-hoc "extract text
  // from a screenshot" stack (drop image, copy text to clipboard).
  vision: {
    ocr(opts) {
      const o = opts || {};
      return request({
        type: "vision.ocr",
        image: o.image,
        languages: o.languages,
        recognitionLevel: o.recognitionLevel || "accurate"
      });
    },
    // VNDetectFaceRectanglesRequest. Returns
    //   { observations: [{ boundingBox: {x,y,w,h}, confidence,
    //                      roll?, yaw?, pitch? }] }
    // boundingBox is normalized 0..1, top-left origin. Head-pose angles are
    // in radians; absent when Vision can't estimate. No identity / landmarks.
    faces(opts) {
      const o = opts || {};
      return request({ type: "vision.faces", image: o.image });
    },
    // Perceptual hash via VNGenerateImageFeaturePrintRequest. Returns
    //   { print: base64, elementCount, elementType }
    // where `print` is an opaque blob — store it (SQLite, JSON) and later
    // pass two prints to .featurePrintDistance for an L2 similarity score.
    //   const a = await sd.vision.featurePrint({ image: imgA });
    //   const b = await sd.vision.featurePrint({ image: imgB });
    //   const { distance } = await sd.vision.featurePrintDistance(a.print, b.print);
    //   // distance ≈ 0 → near-identical; larger → less similar
    featurePrint(opts) {
      const o = opts || {};
      return request({ type: "vision.featurePrint", image: o.image });
    },
    featurePrintDistance(a, b) {
      return request({ type: "vision.featurePrintDistance", a, b });
    },
    // VNGenerateForegroundInstanceMaskRequest (macOS 14+). Returns
    //   { dataURL: "data:image/png;base64,...", width, height }
    // — the original image with the background made transparent. Returns
    // null on macOS 13 (capability gap, not an error) or when no subject is
    // detected. Same engine Photos.app uses for long-press subject lift.
    subjectMask(opts) {
      const o = opts || {};
      return request({ type: "vision.subjectMask", image: o.image });
    },
    // VNDetectHumanBodyPoseRequest. Returns
    //   { bodies: [{ joints: { nose, leftEye, rightShoulder, ... :
    //                         { x, y, confidence } }, confidence }] }
    // Joint positions are normalized 0..1, top-left origin. Joints with
    // confidence < 0.1 are dropped to avoid noise. Multiple bodies per
    // frame. Each named joint: nose, leftEye, rightEye, leftEar, rightEar,
    // leftShoulder, rightShoulder, neck, leftElbow, rightElbow, leftWrist,
    // rightWrist, leftHip, rightHip, root, leftKnee, rightKnee, leftAnkle,
    // rightAnkle.
    bodyPose(opts) {
      const o = opts || {};
      return request({ type: "vision.bodyPose", image: o.image });
    }
  },
  // Current location signal: { lat, lon, accuracy, altitude?, heading?, speed?, timestamp }.
  // macOS asks for Location authorization the first time a stack with the
  // "location" permission loads. Returns null until granted + first fix.
  location: channel("location"),
  // Attached USB devices: [{ vendorID, productID, vendorName?, productName?,
  //   serialNumber?, locationID }, ...]. Fires on attach/detach via IOKit.
  usb: channel("usb"),
  // Mounted volumes via DiskArbitration. One-shot snapshot:
  //   const disks = await sd.disks.list();
  //   // → [{ name, mountPoint, fs?, removable?, ejectable?, size?, internal? }, ...]
  // Live changes via `handles: ["sd.disk.mounted", "sd.disk.unmounted"]` in
  // the stack manifest + window.onBang_sd_disk_mounted(detail) / _unmounted.
  disks: {
    list() { return request({ type: "disks.list" }); }
  },
  // Video capture devices: [{ id, name, position, isInUse, manufacturer? }, ...].
  // Fires on connect / disconnect via AVFoundation, and on per-device
  // isInUseByAnotherApplication KVO. Use for "camera in use" indicators
  // (the red Continuity Camera dot equivalent). Enumeration is metadata-only
  // and does NOT trigger the TCC camera prompt — stackd never opens a stream.
  camera: channel("camera"),
  spaces: {
    all: channel("spaces"),
    // Spaces this window is on, by CGWindowID — Promise<number[]>.
    // Backed by SLSCopySpacesForWindows.
    windowSpaces(id) { return request({ type: "spaces.windowSpaces", id }); },
    // CGWindowIDs of minimized windows on a space — Promise<number[]>.
    minimizedWindows(spaceID) { return request({ type: "spaces.minimizedWindows", spaceID }); }
  },
  menu: {
    // Native NSMenu at the current cursor position. items is an array of
    //   { id, title, checked?, enabled?, separator?, submenu? }
    // Resolves with the picked id, or null on cancel.
    popup(items) { return request({ type: "menu.popup", items: items || [] }); }
  }
};

// ── Reactive sugar: sd.bind + sd.tpl ────────────────────────────────────────
// `sd.bind(target, signal, fmt?)` is the alternative to writing
// `signal.subscribe(v => el.textContent = fmt(v))` by hand for every binding.
// Target dispatch is by shape:
//   Element                       → set textContent
//   [Element, "html"]             → set innerHTML
//   [Element, "value"]            → set .value (form inputs)
//   [Element, "data-foo"]         → set dataset.foo
//   [Element, "attr.foo"]         → setAttribute("foo", v)
//   [Element, "style.--var"]      → style.setProperty("--var", v)
//   [Element, "class.foo"]        → classList.toggle("foo", !!v)
// `signal` can be a single sd.* channel/signal OR an array of them; the
// formatter is called with each .peek() value spread as args.
function applyToTarget(target, value) {
  if (target instanceof Element) {
    // textContent coerces null/undefined to "null"/"undefined" strings — guard explicitly.
    target.textContent = value == null ? "" : value;
    return;
  }
  if (Array.isArray(target)) {
    const [el, kind] = target;
    if (!(el instanceof Element) || typeof kind !== "string") return;
    if (kind === "html")              el.innerHTML = value == null ? "" : String(value);
    else if (kind === "value")        el.value     = value == null ? "" : value;
    else if (kind.startsWith("data-"))  el.dataset[kind.slice(5)] = value == null ? "" : String(value);
    else if (kind.startsWith("attr."))  { value == null ? el.removeAttribute(kind.slice(5)) : el.setAttribute(kind.slice(5), String(value)); }
    else if (kind.startsWith("style.")) el.style.setProperty(kind.slice(6), value == null ? "" : String(value));
    else if (kind.startsWith("class.")) el.classList.toggle(kind.slice(6), !!value);
  }
}

// All live sd.bind subscriptions, released en masse on `stackd:unload`. Caps
// the worst case of `sd.tpl` leaking subscriptions (detached DOM nodes whose
// bindings stay subscribed) at stack lifetime. Within a stack, callers that
// churn dynamic UI should hold the unsub from sd.bind and call it themselves.
const __sdBindUnsubs = new Set();
window.addEventListener("stackd:unload", () => {
  for (const u of __sdBindUnsubs) { try { u(); } catch (e) {} }
  __sdBindUnsubs.clear();
});

function sdBind(target, source, fmt) {
  const sources = Array.isArray(source) ? source : [source];
  // Type guard: the most common misuse is passing the wrong object (e.g. the
  // namespace `sd.windows` instead of `sd.windows.focused`, or a MenubarItem
  // proxy from sd.menubar.addItem). Catch it loudly instead of throwing
  // deep inside .peek().
  for (const s of sources) {
    if (!s || typeof s.peek !== "function" || typeof s.subscribe !== "function") {
      throw new TypeError(
        "sd.bind: source is not a signal (missing .peek/.subscribe). " +
        "Use a channel like sd.battery or sd.windows.focused, not a namespace or proxy."
      );
    }
  }
  const format  = fmt || ((v) => v);
  const apply = () => applyToTarget(target, format(...sources.map(s => s.peek())));
  const unsubs = sources.map(s => s.subscribe(apply));
  const dispose = () => {
    for (const u of unsubs) u();
    __sdBindUnsubs.delete(dispose);
  };
  __sdBindUnsubs.add(dispose);
  return dispose;
}

// `sd.tpl` — tagged-template helper. Returns an Element (single root) or a
// DocumentFragment (multiple top-level nodes) with `${signal}` interpolations
// auto-bound and `${value}` non-signal interpolations rendered as text.
// Query against the fragment (not its firstElementChild) so a top-level
// `${signal}` interpolation — where the placeholder span IS the root — still
// binds. querySelectorAll on an Element skips itself.
let __sdTplCounter = 0;
function sdTpl(strings, ...exprs) {
  const slotAttr = `data-sd-slot-${__sdTplCounter++}`;
  const placeholders = exprs.map((_, i) => `<span ${slotAttr}="${i}"></span>`);
  const html = strings.reduce((acc, s, i) => acc + s + (placeholders[i] || ""), "");
  const tmpl = document.createElement("template");
  tmpl.innerHTML = html.trim();
  tmpl.content.querySelectorAll(`[${slotAttr}]`).forEach(slot => {
    const idx = +slot.getAttribute(slotAttr);
    const expr = exprs[idx];
    if (expr && typeof expr.subscribe === "function" && typeof expr.peek === "function") {
      sdBind(slot, expr);
    } else {
      slot.textContent = expr == null ? "" : String(expr);
    }
  });
  // If the template produces exactly one Element with no surrounding text
  // nodes, return that Element (common case). Otherwise return the fragment
  // so callers can `.append(...)` multi-root templates.
  const frag = tmpl.content;
  if (frag.childNodes.length === 1 && frag.firstChild instanceof Element) {
    return frag.firstElementChild;
  }
  return frag;
}

sd.bind = sdBind;
sd.tpl  = sdTpl;

// ── Template syntax: {{ sd.battery.percent }} in HTML ──────────────────────
// Walks the document at load time, finds `{{ ... }}` in text content and
// attribute values, compiles each as a JS expression, subscribes to whichever
// sd.* signals it references, and updates the DOM on every fire. Lets simple
// stacks skip writing `sd.bind(...)` and `<script>` entirely.
//
// Limitations:
//   - Dependency tracking is regex-based: `{{ sd.battery.percent }}` finds
//     `sd.battery` in the source and subscribes. `const b = sd.battery;
//     b.percent` won't track because the regex never sees the alias. For
//     dynamic usage, drop down to `<script>` + `sd.bind`.
//   - Expressions wrap in try/catch and substitute "" on throw, so
//     `{{ sd.battery.percent }}` renders empty until the first sample arrives
//     (no manual `b?.percent` ceremony needed in the common case).
//   - <script> and <style> contents are skipped — they're not display surface.

// Lookup of every signal exposed on `sd.*` that templates can auto-subscribe
// to. Path strings match what the expression author writes (e.g.
// "windows.focused" for `{{ sd.windows.focused.title }}`). Longer paths are
// matched first so "windows.focused" wins over "windows".
const __sdSignalPaths = {
  "battery":            sd.battery,
  "mouse":              sd.mouse,
  "appearance":         sd.appearance,
  "app.frontmost":      sd.app.frontmost,
  "windows.focused":    sd.windows.focused,
  "windows.all":        sd.windows.all,
  "input.layout":       sd.input.layout,
  "net.wifi":           sd.net.wifi,
  "net.lan":            sd.net.lan,
  "audio.output":       sd.audio.output,
  "display.all":        sd.display.all,
  "media.nowPlaying":   sd.media.nowPlaying,
  "pasteboard.changed": sd.pasteboard.changed,
  "apps.running":       sd.apps.running,
  "apps.changed":       sd.apps.changed,
  "spaces.all":         sd.spaces.all,
  "caffeinate":         sd.caffeinate,
  "displayLink":        sd.displayLink,
  "host.load":          sd.host.load,
  "sensors":            sd.sensors,
  "touchdevice":        sd.touchdevice,
  "location":           sd.location,
  "usb":                sd.usb,
  "camera":             sd.camera,
};

// Sort once, longer-first, so "windows.focused" matches before "windows" —
// otherwise the shorter prefix would always win and the longer path's signal
// would never get subscribed.
const __sdSignalPathsSorted = Object.keys(__sdSignalPaths)
  .sort((a, b) => b.length - a.length);

function __sdCompilePlaceholder(expr) {
  let fn;
  try {
    fn = new Function("sd", "return (" + expr + ");");
  } catch (e) {
    console.error("[stackd] template parse error in {{", expr.trim(), "}}:", String(e));
    fn = () => "";
  }
  const deps = new Set();
  for (const path of __sdSignalPathsSorted) {
    const re = new RegExp("\\bsd\\." + path.replace(/\./g, "\\.") + "\\b");
    if (re.test(expr)) deps.add(__sdSignalPaths[path]);
  }
  return { fn, deps: [...deps] };
}

function __sdEvalPlaceholder(compiled) {
  try {
    const v = compiled.fn(sd);
    return v == null ? "" : String(v);
  } catch (e) {
    // Typical cause: signal's value is still null, so `sd.battery.percent`
    // throws on the first read. Once the first sample arrives, the
    // subscription re-runs and the value renders.
    return "";
  }
}

function __sdProcessTextNode(textNode) {
  const raw = textNode.nodeValue;
  const re = /\{\{([\s\S]+?)\}\}/g;
  const frag = document.createDocumentFragment();
  let lastIndex = 0;
  let m;
  let hadMatch = false;
  while ((m = re.exec(raw)) !== null) {
    hadMatch = true;
    if (m.index > lastIndex) {
      frag.appendChild(document.createTextNode(raw.slice(lastIndex, m.index)));
    }
    const slot = document.createElement("span");
    const compiled = __sdCompilePlaceholder(m[1]);
    const apply = () => { slot.textContent = __sdEvalPlaceholder(compiled); };
    apply();
    for (const sig of compiled.deps) {
      const unsub = sig.subscribe(apply);
      __sdBindUnsubs.add(unsub);
    }
    frag.appendChild(slot);
    lastIndex = m.index + m[0].length;
  }
  if (!hadMatch) return;
  if (lastIndex < raw.length) {
    frag.appendChild(document.createTextNode(raw.slice(lastIndex)));
  }
  textNode.parentNode.replaceChild(frag, textNode);
}

function __sdProcessAttribute(el, attrName, raw) {
  const re = /\{\{([\s\S]+?)\}\}/g;
  // parts[i] is either a literal string or null (meaning "splice in
  // slots[slotIdx++]"). Cheap concat on every fire.
  const parts = [];
  const slots = [];
  let lastIndex = 0;
  let m;
  while ((m = re.exec(raw)) !== null) {
    parts.push(raw.slice(lastIndex, m.index));
    slots.push(__sdCompilePlaceholder(m[1]));
    parts.push(null);
    lastIndex = m.index + m[0].length;
  }
  parts.push(raw.slice(lastIndex));

  const apply = () => {
    let out = "";
    let slotIdx = 0;
    for (const p of parts) out += p === null ? __sdEvalPlaceholder(slots[slotIdx++]) : p;
    el.setAttribute(attrName, out);
  };
  apply();
  const allDeps = new Set();
  for (const s of slots) for (const d of s.deps) allDeps.add(d);
  for (const sig of allDeps) {
    const unsub = sig.subscribe(apply);
    __sdBindUnsubs.add(unsub);
  }
}

function __sdCompileTemplates(root) {
  const SKIP = new Set(["SCRIPT", "STYLE"]);
  const PROBE = /\{\{[\s\S]+?\}\}/;

  // Collect text nodes first, mutate after — mutating during walk skips siblings.
  const textNodes = [];
  const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      if (n.parentNode && SKIP.has(n.parentNode.nodeName)) return NodeFilter.FILTER_REJECT;
      return PROBE.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }
  });
  let t;
  while ((t = tw.nextNode())) textNodes.push(t);
  for (const node of textNodes) __sdProcessTextNode(node);

  // Attributes — same shape, element walker.
  const ew = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let el;
  const attrJobs = [];
  while ((el = ew.nextNode())) {
    if (SKIP.has(el.nodeName)) continue;
    for (const attr of Array.from(el.attributes)) {
      if (PROBE.test(attr.value)) attrJobs.push([el, attr.name, attr.value]);
    }
  }
  for (const [e, name, raw] of attrJobs) __sdProcessAttribute(e, name, raw);
}

// Guard against double-compilation if an explicit `import { sd }` in a stack
// races with the auto-injected runtime loader. ES modules dedup by URL so
// the body only runs once anyway — guard is belt-and-suspenders.
if (!window.__sd_templates_compiled) {
  window.__sd_templates_compiled = true;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => __sdCompileTemplates(document));
  } else {
    __sdCompileTemplates(document);
  }
}

// Handshake: tell native we're ready so it can replay buffered state.
try {
  window.webkit.messageHandlers.sd.postMessage({ type: "ready" });
} catch (e) {
  console.error("ready handshake failed", String(e));
}
