// sd://runtime/api.js
// The `sd.*` namespace exposed to every stack.

function signal(initial, name) {
  let value = initial;
  const subs = new Set();
  const base = {
    get value() { return value; },
    set value(next) {
      if (Object.is(next, value)) return;
      value = next;
      for (const s of subs) s(value);
    },
    // subscribe(fn) — fire `fn` on every channel value change (default).
    // subscribe(fn, { interval: 5 }) — additionally ask native to throttle
    //   its push for this stack on this channel to one every 5 seconds.
    //   Backed by the `channel.setInterval` IPC; only honored by
    //   poll-driven channels (sensors / host.load / display.all). Event-
    //   driven channels (mouse, frontApp, audio…) ignore the interval but
    //   the JS-side subscribe still works.
    //
    // The interval is per-stack (not per-callback) because the IPC sets a
    // single cadence on the bridge's channel push. If a stack subscribes
    // twice on the same channel with different intervals, the last call
    // wins. Stacks that need divergent cadences should multiplex from a
    // single subscriber.
    subscribe(fn, opts) {
      subs.add(fn);
      fn(value);
      if (opts && typeof opts.interval === "number" && name) {
        request({ type: "channel.setInterval", name, interval: opts.interval });
      }
      return () => subs.delete(fn);
    },
    peek() { return value; },
    // Await the first value matching `predicate` (default: any non-null).
    // Resolves synchronously-microtask if `peek()` already matches; otherwise
    // subscribes and unsubscribes on first match. Lets stacks write
    //   const m = await sd.mouse.first();
    // instead of hand-rolling subscribe+unsub at init time.
    first(predicate) {
      const pred = (typeof predicate === "function") ? predicate : (v) => v != null;
      if (pred(value)) return Promise.resolve(value);
      return new Promise((resolve) => {
        let unsub;
        const handler = (v) => {
          if (!pred(v)) return;
          unsub();
          resolve(v);
        };
        unsub = this.subscribe(handler);
      });
    },
  };
  // Proxy fall-through: `sd.appearance.dark` reads `dark` off the current
  // payload when the signal itself doesn't own that key. Lets templates
  // (and `{{ sd.battery.percent }}` style placeholders) skip the manual
  // `.value` ceremony. Own keys (value/subscribe/peek + anything added via
  // Object.assign for RPC-style methods like sd.mouse.warp) shadow the
  // payload, so existing call sites keep working.
  return new Proxy(base, {
    get(target, prop, receiver) {
      if (prop in target) return Reflect.get(target, prop, receiver);
      const v = value;
      if (v != null && typeof v === "object") return v[prop];
      return undefined;
    }
  });
}

const channels = Object.create(null);
function channel(name, initial = null) {
  if (!channels[name]) channels[name] = signal(initial, name);
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
// DN callbacks routed by mint id. Populated by sd.broadcasts.subscribe.
const broadcastHandlers = new Map();
window.__sd_broadcast_fire = (id, payload) => {
  const fn = broadcastHandlers.get(id);
  if (fn) fn(payload);
};
// Custom-URL-scheme callbacks routed by mint id. Populated by
// sd.urlhandler.register. Native fires window.__sd_urlhandler_fire(id, event)
// on every matching GURL Apple Event for the registered scheme.
const urlHandlerHandlers = new Map();
window.__sd_urlhandler_fire = (id, payload) => {
  const fn = urlHandlerHandlers.get(id);
  if (fn) fn(payload);
};
// Streamed proc callbacks routed by mint id. Populated by sd.proc.stream.
// Native fires window.__sd_proc_stream_fire(id, {stream, chunk}) for each
// stdout/stderr chunk and once at exit with {stream:"exit", code, signal?}.
// Handler is removed on exit so a late chunk (shouldn't happen) is dropped.
const procStreamHandlers = new Map();
window.__sd_proc_stream_fire = (id, payload) => {
  const fn = procStreamHandlers.get(id);
  if (!fn) return;
  try { fn(payload); } catch (e) { try { console.error("[stackd] proc.stream callback threw:", e); } catch (_) {} }
  if (payload && payload.stream === "exit") procStreamHandlers.delete(id);
};
// sd.overlay no longer round-trips JS draw callbacks. The daemon hosts a
// per-overlay WKWebView and pushes `window.sd.target = {x,y,w,h}` into it
// each vsync; the overlay's own HTML/CSS/JS handles rendering. attach()
// mints an id and returns a thin handle whose `.detach()` closes the panel.
// HTTP servers: serverId → callback(req). One callback per server; the
// stack handles route dispatch, CORS, Content-Type, and static-asset
// lookup itself. Native fires window.__sd_http_request(serverId, reqId, req)
// on every request; JS resolves with sd.httpserver.respond(reqId, response).
const httpServers = new Map();
window.__sd_http_request = async (serverId, reqId, req) => {
  const callback = httpServers.get(serverId);
  if (!callback) {
    await request({ type: "httpserver.respond", reqId, status: 503, headers: {}, body: "no server" });
    return;
  }
  let resp;
  try { resp = await callback(req); }
  catch (e) { resp = { status: 500, body: String(e) }; }
  resp = resp || {};
  // bodyEncoding: "base64" — body is a base64 string; the daemon decodes it
  // before writing to the wire (Content-Length reflects the decoded byte
  // count). Use this to serve PNGs / PDFs / any binary payload alongside
  // `sd.fs.read(path, { encoding: "base64" })`. Anything else (or missing)
  // sends body verbatim as a UTF-8 string — the original behavior.
  await request({
    type: "httpserver.respond",
    reqId,
    status:  resp.status  || 200,
    headers: resp.headers || {},
    body:    resp.body == null ? "" : String(resp.body),
    bodyEncoding: resp.bodyEncoding || null
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

// Handler-registry helper for the native-mints-an-id pattern shared by
// sd.hotkey.bind, sd.broadcasts.subscribe, sd.httpserver.serve, and the bind
// portion of sd.menubar.addItem. Native returns the id from
// `request(bindPayload)`; we stash `callback` under it so the matching
// `__sd_<name>_fire` dispatcher can route by id. Returns null on failure so
// callers can early-out without registering a stale entry.
//
// Not used by sd.fs.watch (JS mints the watchId before the request) or by
// the menubar handler (which stores a structured callback shape — see
// that site for inline registration).
async function registerHandler(map, bindPayload, callback) {
  const id = await request(bindPayload);
  if (id == null || id === false) return null;
  map.set(id, callback);
  return id;
}
function unregisterHandler(map, id, unbindPayload) {
  map.delete(id);
  return request(unbindPayload);
}

// Wrap a bang name as a subscribe-able signal. Installs a
// window.onBang_<bangSlug> handler that pushes detail into the channel.
// Used by sd.windows.{created,destroyed,...}. The bangSlug is the sanitized
// name (Bridge.swift lowercases + replaces non-alphanumerics with _), so
// 'sd_window_created' here matches the daemon's onBang_sd_window_created
// dispatch path.
function __windowBang(bangSlug) {
  const ch = signal(null, "bang:" + bangSlug);
  const slot = "onBang_" + bangSlug;
  // First subscriber wins the slot; secondary callers chain via .subscribe.
  // Idempotent: re-install on hot-reload picks up the latest channel ref.
  window[slot] = (detail) => { ch.value = detail; };
  return ch;
}

// Generic slot-registration: replaces the `window.on<Kind>_<name> = fn`
// global-mutation pattern with a call that returns a disposer. The daemon
// still dispatches via the same window slot, so this is purely a JS-side
// ergonomic shim — back-compat is total. Kind is "Tap" / "Hotkey" / etc.
// (already capitalized to match the daemon's fireGlobal slot names in
// Bridge.swift). Name is the manifest-declared callback id (unsanitized
// for hotkey/tap — the daemon dispatches against the raw name).
function __registerSlotHandler(kindPascal, name, fn) {
  const slot = "on" + kindPascal + "_" + name;
  const prior = window[slot];
  window[slot] = fn;
  return () => {
    // Only clear if we're still the active handler; otherwise a later
    // .on() with the same name has rightfully replaced us.
    if (window[slot] === fn) window[slot] = prior || undefined;
  };
}

// Bang slugging — matches Bridge.swift sanitization (lowercase, non-alphanumeric
// → underscore). Producer side fires the original `name`; the daemon dispatches
// to `window.onBang_<slug>`. Consumer side resolves the same slug so producers
// and consumers find each other through one shared router.
function __bangSlug(name) {
  return String(name).toLowerCase().replace(/[^a-z0-9]/g, "_");
}

// Bang declarations: shared router per slug, plus a set of listeners.
// First declare() installs the router on window.onBang_<slug>, chaining any
// pre-existing handler. Multiple consumers can attach via .on(fn); each gets
// a disposer. Legacy stacks that overwrite window.onBang_<slug> AFTER declare()
// will still take over the slot (last-write-wins is the existing contract);
// adoption is monotonic — once everyone uses declare() this stays clean.
const bangDeclarations = new Map();
function __ensureBangRouter(slug) {
  let dec = bangDeclarations.get(slug);
  if (dec) return dec;
  dec = { listeners: new Set() };
  bangDeclarations.set(slug, dec);
  const slot = "onBang_" + slug;
  const prior = window[slot];
  window[slot] = (detail) => {
    if (prior) { try { prior(detail); } catch (_) {} }
    for (const fn of dec.listeners) { try { fn(detail); } catch (_) {} }
  };
  return dec;
}

// Timer registry — every timer minted through sd.timer.* lands here so
// the pagehide listener below can clear pending callbacks before the
// document unloads / reloads. Plain setTimeout / setInterval is NOT
// tracked; stacks that want reload-safe lifecycle must use sd.timer.
const __sdTimers = new Set();
function __sdTrack(id) { __sdTimers.add(id); return id; }
function __sdCancel(id, isInterval) {
  __sdTimers.delete(id);
  if (isInterval) clearInterval(id); else clearTimeout(id);
}
// On hot-reload the WKWebView reloads its document but the JSC heap +
// pending timers survive — old timeouts would fire into the new document
// with stale closures. pagehide is the WebKit signal for "the document is
// about to go away" and runs synchronously before the new load begins.
window.addEventListener("pagehide", () => {
  for (const id of __sdTimers) { try { clearTimeout(id); clearInterval(id); } catch (_) {} }
  __sdTimers.clear();
});

// sd.timer.* — reload-safe scheduling. Every minted handle auto-cancels on
// pagehide AND returns a disposer for explicit cancellation. The whole
// point: stacks stop hand-rolling { let t = null; clearTimeout(t); t = … }
// state machines that leak across hot-reload.
const timer = {
  // One-shot delayed call. Returns a disposer that cancels the pending fire.
  //   const stop = sd.timer.timeout(() => panel.hide(), 400);
  //   stop();   // cancel before it fires
  timeout(fn, ms) {
    const id = __sdTrack(setTimeout(() => { __sdTimers.delete(id); fn(); }, ms));
    return () => __sdCancel(id, false);
  },
  // Repeating call at `ms` cadence. Returns a disposer; remember it — there
  // is no other way to stop the interval. Auto-clears on pagehide regardless.
  //   const stop = sd.timer.interval(() => tick(), 1000);
  interval(fn, ms) {
    const id = __sdTrack(setInterval(fn, ms));
    return () => __sdCancel(id, true);
  },
  // Trailing-edge debounce. Returns a callable that delays invoking `fn`
  // until `ms` has elapsed since the last call. Disposer plus a `.cancel()`
  // method on the callable itself (matches sd.util.debounce's prior shape).
  //   const onChange = sd.timer.debounce(saveLayout, 300);
  //   sd.windows.all.subscribe(onChange);
  debounce(fn, ms) {
    let t = null;
    const wrapped = function (...args) {
      if (t !== null) __sdCancel(t, false);
      t = __sdTrack(setTimeout(() => { __sdTimers.delete(t); t = null; fn.apply(this, args); }, ms));
    };
    wrapped.cancel = () => { if (t !== null) { __sdCancel(t, false); t = null; } };
    return wrapped;
  },
  // Leading-edge throttle. First call fires immediately; subsequent calls
  // within `ms` are dropped; trailing edge re-arms after the window expires.
  //   const tick = sd.timer.throttle(updateHUD, 100);
  throttle(fn, ms) {
    let last = 0, scheduled = null;
    return function (...args) {
      const now = Date.now();
      const remaining = ms - (now - last);
      if (remaining <= 0) {
        last = now;
        if (scheduled !== null) { __sdCancel(scheduled, false); scheduled = null; }
        fn.apply(this, args);
      } else if (scheduled === null) {
        scheduled = __sdTrack(setTimeout(() => {
          last = Date.now();
          __sdTimers.delete(scheduled);
          scheduled = null;
          fn.apply(this, args);
        }, remaining));
      }
    };
  }
};

// Pure-JS helpers — no IPC, no permission. Same shape across every
// stack: stop reinventing debounce, throttle, and per-screen helpers.
// debounce / throttle delegate to sd.timer.* so existing call sites
// automatically gain pagehide auto-cleanup without a code change.
const util = {
  // Trailing-edge debounce. Returns a function that delays invoking `fn`
  // until `ms` has elapsed since the last call. `.cancel()` aborts a
  // pending call. Used to consolidate sd.windows.* bursts, drag-end
  // detection, search-as-you-type, etc.
  //   const onChange = sd.util.debounce(saveLayout, 300);
  //   sd.windows.all.subscribe(onChange);
  debounce(fn, ms) { return timer.debounce(fn, ms); },
  // Leading-edge throttle. First call fires immediately; subsequent
  // calls within `ms` are dropped. Trailing edge re-arms after the
  // window expires.
  //   const tick = sd.util.throttle(updateHUD, 100);
  //   sd.mouse.subscribe(tick);
  throttle(fn, ms) { return timer.throttle(fn, ms); }
};

export const sd = {
  util,
  timer,
  // Per-instance screen info, injected before this script runs (see Bridge.swift).
  // Read .current synchronously — items like spacenum + brightness need to
  // know which screen they're rendered on without an async round-trip.
  screen:     { current: window.__sd_screen || null },
  battery:    channel("battery"),
  mouse:      Object.assign(channel("mouse"), {
    // Subscribe payload: { x, y, display: { id, frame: {x,y,w,h} } | null }.
    // The `display` field is the screen containing the cursor at push time —
    // daemon-precomputed so stacks don't reimplement the for-each-display
    // `forPoint` loop on every 30Hz tick. null when off-screen (mid-display-
    // arrangement race or before screens come online).
    //   sd.mouse.subscribe(m => {
    //     if (!m || !m.display) return;
    //     const localX = m.x - m.display.frame.x;
    //   });
    //
    // Move the cursor without clicking. Top-left origin (same coord space
    // as sd.windows.focused().frame).
    //   sd.mouse.warp(100, 200);
    warp(x, y) { return request({ type: "mouse.warp", x, y }); }
  }),
  appearance: channel("appearance"),
  app:        {
    frontmost: channel("frontApp"),
    // Fires when the frontmost app changes (F15 split of the legacy
    // sd.windows.focused union). Payload matches sd.app.frontmost — same
    // { app, pid, bundleId, ... } dict shape. Permission: "app".
    activated: channel("appActivated")
  },
  windows:    {
    // Subscribe payload: {
    //   id, pid, app, bundleId, title, frame: {x,y,w,h},
    //   display: { id, frame } | undefined,
    //   space:   <CGSpaceID Int> | undefined
    // }
    // - bundleId: stable across launches (pid recycles, bundleId doesn't);
    //   stacks routing by app should key on this, not on pid or name.
    // - display: the screen containing the window's top-left at push time,
    //   daemon-precomputed so stacks don't reimplement the forPoint loop.
    //   Omitted when off-screen.
    // - space: first CGSpaceID the window appears on. Multi-space windows
    //   (sticky / fullscreen aux) still surface a usable value here; call
    //   sd.spaces.forWindow(id) for the full set.
    focused: channel("focusedWindow"),
    // Each entry: { id, app, pid, title, onscreen, addressable,
    //   isStandard, isMinimized, frame: {x,y,w,h},
    //   display: { id, frame } | undefined }
    // The `display` field mirrors the focused-channel enrichment so per-
    // display tiling / switcher stacks don't paginate sd.display.forPoint
    // calls. `space` deliberately omitted from the list entries (the
    // per-window CGS lookup is cheap but a 50-window push would still pay
    // 50 of them); call sd.spaces.forWindow(id) for that.
    all:     channel("windowsAll", []),
    // Transition deltas alongside the full-list `all` channel: same shape
    // as sd.apps.changed — { added: [...], removed: [...], changed: [...] }.
    // Identity is CGWindowID; "changed" detects title + frame transitions.
    // Suppresses the first-tick "every window added" — for that subscribe
    // to .all. Consumers that diff sd.windows.all themselves (windowscape,
    // undoclose, framemaster) pay diff-size after migration instead of
    // full-list-size on every push.
    changed: channel("windowsChanged"),
    // Lifecycle channels — sugar over the sd.window.* bangs. Stack must
    // declare `handles: ["sd.window.created", ...]` in stack.json for the
    // daemon to route the bang to it. Each .subscribe(fn) re-fires whenever
    // the matching bang lands.
    //   sd.windows.created.subscribe(({id, app, frame}) => ...);
    //   sd.windows.destroyed.subscribe(({id}) => ...);
    //   sd.windows.moved.subscribe(({id, frame}) => ...);
    //   sd.windows.resized.subscribe(({id, frame}) => ...);
    //   sd.windows.minimized.subscribe(({id}) => ...);
    //   sd.windows.deminimized.subscribe(({id}) => ...);
    // The underlying bang names are still legal; this just removes the
    // window.onBang_sd_window_* boilerplate.
    created:      __windowBang("sd_window_created"),
    destroyed:    __windowBang("sd_window_destroyed"),
    moved:        __windowBang("sd_window_moved"),
    resized:      __windowBang("sd_window_resized"),
    minimized:    __windowBang("sd_window_minimized"),
    deminimized:  __windowBang("sd_window_deminimized"),
    // F15 split — granular per-event-type channels alongside the legacy
    // union `focused` channel. Each fires the moment AX reports the matching
    // notification, so stacks can subscribe to exactly what they need.
    //   sd.windows.focusedChanged — focused window of frontmost app changed
    //     (same payload as sd.windows.focused: { id, app, pid, title, frame })
    //   sd.windows.titleChanged — title of the focused window changed
    //     (small payload: { id, app, title, pid } — no frame to keep it cheap)
    // sd.windows.focused still fires as the union of both for back-compat.
    // Permission: "windows" (same as the union channel).
    focusedChanged: channel("focusedChanged"),
    titleChanged:   channel("titleChanged"),
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
    // Probed setFrame: applies the geometry then reads back what AX actually
    // accepted, so callers can detect apps that refused part of the resize
    // (Calculator, fixed-size panels, Browser at its min width). Returns
    //   { ok: bool, actual: {x,y,w,h} | null }
    // Use when building / updating a window-constraint cache (e.g. the
    // windowscape tiler's per-window min/max inference). Same permission
    // as setFrame: "windows".
    setFrameProbed(id, frame) {
      const f = frame || {};
      return request({ type: "windows.byId.setFrameProbed", id, x: f.x, y: f.y, w: f.w, h: f.h });
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
    frame(id)  { return request({ type: "windows.byId.frame", id }); },
    // Raw AX hints for picking a corner radius in stack code. Returns
    //   { toolbarPresent: bool, role: string|null, subrole: string|null }
    // Stacks compose their own 26/16/0 mapping — e.g. an outline stack writes
    //   const h = await sd.windows.cornerHints(id);
    //   const r = h.subrole === "AXSystemDialog" || h.role === "AXScrollArea"
    //             ? 0 : h.toolbarPresent ? 26 : 16;
    // matching Tahoe's WindowServer rounding.
    cornerHints(id) { return request({ type: "windows.byId.cornerHints", id }); },
    // Traffic-light button frames (in the same global coord space as
    // `frame`). Returns
    //   { close:    {x,y,w,h} | null,
    //     zoom:     {x,y,w,h} | null,
    //     minimize: {x,y,w,h} | null }
    // or null when the window is unaddressable. Per-button fields are null
    // when that dot doesn't exist on this window (some panels, helper
    // windows). One AX walk per call — a stack that needs button rects for
    // many windows should still batch by id at its own cadence (focus
    // change / moved / resized) rather than poll. windowscape's port of
    // the lua fullscreen_ui.lua intercept layer uses this to route clicks
    // on the native yellow/green/red dots to custom handlers.
    buttonFrames(id) { return request({ type: "windows.byId.buttonFrames", id }); },
    // Batch reader: one round-trip → all curated properties at once.
    // Returns null when the window is unaddressable; otherwise:
    //   { frame, title, role, subrole, isMinimized, isFullscreen, isMain,
    //     isStandard, hasToolbar, cornerHints }
    // Use this instead of 4-9 sequential calls (`frame`, `title`,
    // `isStandard`, `cornerHints`, ...) when a stack needs several
    // properties at attach/render time. overlay-border was 4 RPCs
    // per focus change; sd.windows.info collapses that to 1.
    info(id) { return request({ type: "windows.byId.info", id }); },
    // Curated AX readers — per-window properties straight off WindowsByID,
    // so stacks don't have to round-trip through `sd.ax.*` for the common
    // cases. Permission: "windows" (each gates on the same key as the
    // setters). Returns null on AX failure; isMinimized/isFullscreen return
    // false. title returns null when the window has no title set.
    title(id)         { return request({ type: "windows.byId.title", id }); },
    role(id)          { return request({ type: "windows.byId.role", id }); },
    subrole(id)       { return request({ type: "windows.byId.subrole", id }); },
    isMinimized(id)   { return request({ type: "windows.byId.isMinimized", id }); },
    isFullscreen(id)  { return request({ type: "windows.byId.isFullscreen", id }); },
    hasToolbar(id)    { return request({ type: "windows.byId.hasToolbar", id }); },
    // Subrole === "AXStandardWindow". The single most common AX gate tilers
    // and overlays make; saves stacks from baking the comparison into JS.
    //   if (await sd.windows.isStandard(id)) { /* tile / outline / etc */ }
    isStandard(id)    { return request({ type: "windows.byId.isStandard", id }); },
    // Per-window tab list — walks the window's AXTabGroup child (browsers,
    // Finder, terminals). Returns [{ title, selected }, ...] or null when the
    // window has no AXTabGroup. Empty array if the tab group exists but
    // contains no children. Pair with focusTab(id, n) to activate a tab.
    //   const tabs = await sd.windows.tabs(id);
    //   if (tabs) await sd.windows.focusTab(id, tabs.findIndex(t => !t.selected));
    tabs(id)          { return request({ type: "windows.byId.tabs", id }); },
    focusTab(id, index) {
      return request({ type: "windows.byId.focusTab", id, index: index | 0 });
    },
    // Synchronous SPI snapshot via CGSHWCaptureWindowList. Works for
    // hidden / minimized / off-space windows (the AltTab trick) — distinct
    // from sd.display.snapshot which uses ScreenCaptureKit and gates on
    // visibility + Screen Recording TCC.
    //   const png = await sd.windows.snapshot(wid);
    //   const jpg = await sd.windows.snapshot(wid, { format: "jpeg", quality: 0.7 });
    //   // → { dataURL, width, height }  (or null if the SPI is unavailable)
    snapshot(id, opts) {
      const o = opts || {};
      return request({
        type: "windows.byId.snapshot",
        id,
        format:  o.format  || "png",
        quality: o.quality ?? 0.85   // canonical default lives here, not in Swift
      });
    },
    // Atomic multi-window transaction. setFrame calls with an explicit id
    // inside the closure are queued and committed atomically on closure
    // return — every window snaps to its new origin on a single compositor
    // flip instead of cascading. Size still goes through AX per-window (no
    // SLS size symbol exists), so size cascade may still be visible. Calls
    // without an id (which target the AX focused window) bypass batching.
    // Throws-through; queued ops are dropped via commit-empty-then-rethrow.
    async batch(fn) {
      const ok = await request({ type: "windows.batch.begin" });
      if (!ok) return false;
      try {
        await fn();
        return await request({ type: "windows.batch.commit" });
      } catch (e) {
        await request({ type: "windows.batch.commit" });
        throw e;
      }
    }
  },
  // sd.input — keyboard layout signal + curated AX surface for the
  // system-wide focused text element. Replaces the five-call sd.ax.*
  // dance (focused → attribute → parameterizedAttribute → release) muse,
  // palette, and text-expander stacks were doing for every transformation
  // tick.
  //
  //   const f = await sd.input.focusedText();
  //   // → { text, selectedText,
  //   //     selectedRange: { location, length },
  //   //     caretRect: { x, y, w, h } | null,
  //   //     role, subrole, value, pid, app }  | null when no AX-text focus
  //
  //   await sd.input.setSelectedText("hello");        // replace current selection
  //   await sd.input.setSelectedRange(loc, len);      // change selection / move caret
  //
  // Known limitation: Safari / Mail / Firefox WebViews leave
  // kAXSelectedTextAttribute empty even when there's text in the field —
  // selectedText comes back as "" in those cases (the rest of the dict
  // is still populated).
  input: {
    layout:    channel("inputLayout"),
    focusedText()           { return request({ type: "input.focusedText" }); },
    setSelectedText(value)  { return request({ type: "input.setSelectedText", value: String(value ?? "") }); },
    setSelectedRange(location, length) {
      return request({
        type: "input.setSelectedRange",
        location: location | 0,
        length:   length   | 0
      });
    }
  },
  net:        {
    wifi: channel("netWifi"),
    lan:  channel("netLan"),
    // Network reachability — derived from NWPathMonitor on the daemon side.
    //   sd.net.path.subscribe(({ status, interfaces, isConstrained, isExpensive }) => …)
    // status is "satisfied" | "unsatisfied" | "requiresConnection".
    // interfaces is the available route list, ordered by preference, mapped
    // to short strings: "wifi" | "wired" | "cellular" | "loopback" | "other".
    // isConstrained = Low Data Mode; isExpensive = cellular / personal hotspot.
    // The signal stays null until the first NWPath update lands (typically
    // within a few hundred ms of stack load).
    path: channel("netPath"),
    // Aggregate throughput across non-loopback interfaces, polled 1s in
    // the daemon (getifaddrs + if_data byte counters, summed and diffed).
    //   sd.net.throughput.subscribe(({ rxBps, txBps, rxBytes, txBytes }) => …)
    // rxBps / txBps are bytes-per-second over the last second; rxBytes /
    // txBytes are cumulative counters since boot (NIC-reset-dependent).
    // First push lands after the second tick (need two samples to diff) —
    // about 2s after the stack loads. Cadence is `{ interval: N }` on
    // subscribe like other polled channels; daemon stays at 1s natively.
    throughput: channel("netThroughput")
  },
  defaults: {
    read(bundleId, key) {
      return request({ type: "defaults.read", bundleId, key });
    }
  },
  // Default-device curated payloads + per-direction setters + device
  // enumeration. The input channel is a mirror of `output` — same
  // `{ name, volume, muted, deviceName }` shape, but for the default input
  // device. CoreAudio property reads do NOT trigger the microphone TCC
  // prompt (only opening an input stream does), so subscribing to
  // `sd.audio.input` from a stack that just wants to draw a mic-level VU
  // meter is privacy-safe.
  //   sd.audio.output.subscribe(({ volume, muted, deviceName }) => …)
  //   sd.audio.input.subscribe (({ volume, muted, deviceName }) => …)
  //   const inputs  = await sd.audio.devices({ scope: "input"  });
  //   const outputs = await sd.audio.devices({ scope: "output" });
  //   // → [{ id, name, manufacturer?, transportType?, uid?, isDefault }, ...]
  //   await sd.audio.setDefaultDevice(inputs[0].id, "input");
  //   await sd.audio.setInputVolume(0.5);
  //   await sd.audio.setInputMuted(true);
  audio: {
    output:     channel("audioOutput"),
    input:      channel("audioInput"),
    // Per-process audio enumeration. Array of every process currently
    // connected to an audio device:
    //   [{ pid, bundleId, name, playingOutput }, …]
    // playingOutput flips true while the process is producing sound and
    // false the moment it pauses/stops — driven by CoreAudio's
    // kAudioProcessPropertyIsRunningOutput (macOS 14.4+). bundleId/name
    // may be null for system processes without a bundle.
    // Lighter than sd.media.nowPlaying — no track metadata, just "who's
    // making sound" — but covers EVERY app, not just MediaRemote-aware
    // ones. Pair with sd.media.nowPlaying for the rich active pill +
    // bare secondary pills per app.
    processes:  channel("audioProcesses"),
    setVolume(v) { return request({ type: "audio.setVolume", value: v }); },
    setMuted(m)  { return request({ type: "audio.setMuted",  value: !!m }); },
    setInputVolume(v) { return request({ type: "audio.setInputVolume", value: v }); },
    setInputMuted(m)  { return request({ type: "audio.setInputMuted",  value: !!m }); },
    // scope: "input" | "output" (default "output")
    devices(opts) {
      const o = opts || {};
      return request({ type: "audio.devices", scope: o.scope || "output" });
    },
    // id is the AudioDeviceID from `devices()`; scope picks which default
    // slot to update (a device that's both input + output can be the
    // default for one direction without affecting the other).
    setDefaultDevice(id, scope) {
      return request({ type: "audio.setDefaultDevice", id, scope: scope || "output" });
    }
  },
  display: {
    // Per-display info + brightness. Re-fires on screen arrangement changes
    // (NSApplication.didChangeScreenParameters) and every 2s as a brightness
    // poll. Tunable cadence — pass `{ interval }` (seconds) to slow this
    // stack's fanout (event-driven re-fires still arrive):
    //   sd.display.all.subscribe(d => updateUI(d), { interval: 10 });
    all:        channel("displays", []),
    // Transition deltas paralleling sd.windows.changed / sd.apps.changed:
    // { added: [...], removed: [...], changed: [...] }. Identity is
    // displayID; "changed" tracks frame + brightness (arrangement /
    // resolution / slider). First-tick "everything added" suppressed —
    // for the initial list subscribe to .all instead. Permission: "display".
    changed:    channel("displaysChanged"),
    // Display lookup helpers — read sd.display.all's last-pushed value and
    // return the display whose frame contains the given point/window.
    // Replaces the ~5 copies of this loop sitting in cursor-overlay stacks
    // (framemaster, timetrail, sideswipe, windowscape, cloudpad). Returns
    // null if no display matches; caller can fall back to the primary
    // display via `(sd.display.all.peek() || [])[0]`.
    //   const d = sd.display.forPoint(m.x, m.y);
    //   if (d) draw(m.x - d.frame.x, m.y - d.frame.y);
    forPoint(x, y) {
      const list = (sd.display.all.peek && sd.display.all.peek()) || [];
      for (const d of list) {
        const f = d && d.frame;
        if (!f) continue;
        if (x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h) return d;
      }
      return null;
    },
    // forWindow accepts either a window object (with .frame) or a CGWindowID.
    //   sd.display.forWindow(focused) → display
    //   sd.display.forWindow(50)      → display (queries sd.windows.frame(50))
    forWindow(w) {
      if (typeof w === "number") {
        // Caller passed an id. Resolve via the windows API; await is fine
        // because most callers are already in an async handler.
        return sd.windows.frame(w).then(f => {
          if (!f) return null;
          return sd.display.forPoint(f.x + f.w / 2, f.y + f.h / 2);
        });
      }
      if (!w || !w.frame) return null;
      return sd.display.forPoint(w.frame.x + w.frame.w / 2,
                                 w.frame.y + w.frame.h / 2);
    },
    // setBrightness(displayID, value) or setBrightness(value, { displayId })
    //
    // Accepts two call shapes for back-compat:
    //   sd.display.setBrightness(0.5)                — main display
    //   sd.display.setBrightness(displayID, 0.5)     — legacy positional
    //   sd.display.setBrightness(0.5, { displayId }) — preferred
    //
    // value is 0..1 (normalized). External monitors route through DDC/CI
    // over IOAVService — returns false if the IOAVService SPI can't load
    // or no monitor matches the displayId.
    setBrightness(a, b) {
      let displayID, value;
      if (typeof b === "object" && b !== null) {
        // New shape: (value, { displayId })
        value = a;
        displayID = b.displayId ?? b.displayID ?? 0;
      } else if (typeof b === "number") {
        // Legacy positional: (displayID, value)
        displayID = a;
        value = b;
      } else {
        // Single-arg: (value) — main display
        value = a;
        displayID = 0;
      }
      return request({ type: "display.setBrightness", displayID, value });
    },
    // Reads the current brightness back. Returns a Promise<number|null>
    // in 0..1; external monitors that don't implement the DDC read side
    // resolve to null. Main display when displayId omitted.
    getBrightness(opts) {
      const o = opts || {};
      const displayID = o.displayId ?? o.displayID ?? 0;
      return request({ type: "display.getBrightness", displayID });
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

    // Read-only AX walk of every visible menubar status item — third-party
    // app icons + Apple's Spotlight + clock. Returns an array of
    //   { owner, title, x, width, hidden }
    // sorted left-to-right by x. `owner` is the bundle identifier (or
    // localized name) of the app that owns the item. `hidden` flags items
    // pushed past the system's chevron / off-screen (notch overflow on
    // MacBook Pro 14"/16", or too many items for the bar width).
    //
    // Requires the "menubar" permission (same gate as suppress/restore +
    // observe). macOS 14+ Control Center group (Wi-Fi / Bluetooth / Focus
    // / etc.) lives in a separate AXSystemUIServer process and is NOT
    // included — documented limitation, not a bug.
    items() { return request({ type: "menubar.items" }); },

    // Subscribable signal that fires whenever the menubar item set changes
    // (item added / removed / repositioned). Backed by a 2s poll-and-diff
    // — AX has no reliable push for status-item add/remove. Payload is the
    // same shape as items(). Tunable cadence per-stack:
    //   sd.menubar.observe.subscribe(items => render(items), { interval: 5 });
    // Same "menubar" permission gate as items() / suppress / restore.
    observe: channel("menubarItems"),
    // Transition deltas paralleling sd.windows.changed / sd.apps.changed:
    // { added: [...], removed: [...], changed: [...] }. Identity is
    // owner+title (menubar items have no stable id); "changed" tracks
    // x / width / hidden transitions. Suppresses the first-tick
    // "everything added" — for that subscribe to .observe.
    changed: channel("menubarChanged"),

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
      const id = await registerHandler(
        menubarHandlers,
        { type: "menubar.addItem", icon, title, menu, tooltip },
        { onClick, onMenuPick }
      );
      if (id == null) return null;
      return {
        id,
        setTitle(s)       { return request({ type: "menubar.item.setTitle",   id, title: s }); },
        setIcon(iconSpec) { return request({ type: "menubar.item.setIcon",    id, icon: iconSpec }); },
        setMenu(items)    { return request({ type: "menubar.item.setMenu",    id, items }); },
        setTooltip(s)     { return request({ type: "menubar.item.setTooltip", id, tooltip: s }); },
        remove() {
          return unregisterHandler(menubarHandlers, id, { type: "menubar.item.remove", id });
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
    //   await sd.fs.read("~/Notes/today.md")                    // utf8 string
    //   await sd.fs.read("/tmp/cover.png", { encoding: "base64" }) // binary-safe
    // utf8 returns null on non-UTF-8 bytes; base64 always returns a string
    // (empty for a zero-byte file).
    read(path, opts) {
      const o = opts || {};
      return request({ type: "fs.read", path, encoding: o.encoding || "utf8" });
    },
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
    },
    // Extended attributes — Darwin getxattr / setxattr / listxattr / removexattr.
    // Get / set use base64 for the raw bytes so binary plist payloads (Finder
    // tags under `com.apple.metadata:_kMDItemUserTags`, download provenance
    // under `com.apple.metadata:kMDItemWhereFroms`) survive the IPC.
    //   const b64 = await sd.fs.xattr.get(path, "com.apple.metadata:kMDItemWhereFroms");
    //   // → "YnBsaXN0MDDU..." | null
    //   // Decode in stack code: atob(b64) → raw bytes → binary-plist parser.
    //   await sd.fs.xattr.set(path, "com.apple.FinderInfo", btoa(rawBytes));
    //   await sd.fs.xattr.list(path);   // ["com.apple.metadata:kMDItemWhereFroms", ...]
    //   await sd.fs.xattr.remove(path, "com.apple.quarantine");
    // No auto-decoding in v1 — every Apple xattr is binary plist or raw bytes;
    // shipping a plist parser inside the daemon would lock in a v2 surface
    // before the consumers are known. Gated by the same "fs" permission as
    // the rest of sd.fs.
    xattr: {
      get(path, name)        { return request({ type: "fs.xattr.get",    path, name }); },
      set(path, name, value) { return request({ type: "fs.xattr.set",    path, name, value: String(value ?? "") }); },
      list(path)             { return request({ type: "fs.xattr.list",   path }); },
      remove(path, name)     { return request({ type: "fs.xattr.remove", path, name }); }
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
    },
    // Streamed counterpart of exec — progressive stdout/stderr instead of
    // buffer-to-completion. Use for long-running children where you want to
    // surface output as it arrives (tail -f, brew install, ffmpeg, etc.).
    //
    //   const h = await sd.proc.stream(
    //     { cmd: "/usr/bin/tail", args: ["-f", "/var/log/system.log"] },
    //     ({ stream, chunk, code, signal }) => {
    //       if (stream === "stdout") appendLine(chunk);
    //       if (stream === "stderr") logErr(chunk);
    //       if (stream === "exit")   console.log("done", code, signal);
    //     });
    //   ...later...
    //   await h.cancel();   // SIGTERM the child; "exit" still fires.
    //
    // The callback fires once per native chunk (no line buffering — chunks
    // can split mid-line); accumulate yourself if you need full lines.
    // The "exit" event does NOT re-send buffered stdout/stderr — accumulate
    // the chunks if you want a final joined payload.
    async stream(opts, callback) {
      const o = opts || {};
      if (typeof callback !== "function") return null;
      const id = await registerHandler(procStreamHandlers, {
        type: "proc.stream.start",
        cmd:  String(o.cmd ?? ""),
        args: o.args || [],
        env:  o.env,
        cwd:  o.cwd
      }, callback);
      if (id == null) return null;
      return {
        id,
        cancel() {
          // Don't unregister yet — the exit event still needs to land. The
          // handler map deletes itself when "exit" arrives (see __sd_proc_stream_fire).
          return request({ type: "proc.stream.cancel", id });
        }
      };
    }
  },
  // AppleScript / JXA runner — faster than spawning /usr/bin/osascript for
  // every call (NSAppleScript runs in-process). Use for: scripting other apps
  // via Apple Events, querying System Events for window/UI info, anything
  // `tell application X to ...` shaped.
  //   const r = await sd.applescript.run(`return 1 + 1`);            // r.result === 2
  //   const r = await sd.applescript.run(`return Math.PI`, { language: "javascript" });
  //   const r = await sd.applescript.run(`return {1, 2, "three"}`);  // r.result === [1, 2, "three"]
  // Returns: { ok: boolean, result: any, error?: string }.
  // `result` preserves the script's return type — numbers stay numbers, lists
  // become arrays, records become objects, strings stay strings, booleans stay
  // booleans. Void returns are "" so a no-`return` script lands on a string.
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
  // Invoke a Shortcut by name (the user-visible name in the Shortcuts app).
  //   const r = await sd.shortcuts.run("My Shortcut");
  //   const r = await sd.shortcuts.run("Read Text", { input: "hello" });
  //   // → { stdout, stderr, exitCode }
  // The shortcut's final "Stop and output" value lands in stdout; a nonzero
  // exitCode means the run failed (unknown name, mid-shortcut error, denied
  // TCC). First call on a fresh system surfaces the Shortcuts access prompt.
  shortcuts: {
    run(name, opts) {
      const o = opts || {};
      return request({
        type: "shortcuts.run",
        name: String(name ?? ""),
        input: o.input,
        timeout: o.timeout
      });
    }
  },
  events: {
    // Synthesize input. Note: scroll/click also fire your own eventtap
    // handlers if you have any registered. Use with care.
    type(text)            { return request({ type: "events.type", value: text }); },
    key(spec)             { return request({ type: "events.key",  spec }); },
    scroll(dx, dy)        { return request({ type: "events.scroll", dx, dy }); },
    click(x, y, button)   { return request({ type: "events.click", x, y, button: button || "left" }); },
    // Update the runtime cursor-rect gate for a consuming eventtap declared
    // in this stack's manifest (matched by callback name). Three semantics:
    //   - rects = null  → clear the gate (consumer matches on its static
    //                     predicate alone — `keyCodes`, `flagsMask`, etc).
    //   - rects = []    → empty gate; consumer never fires until rects are
    //                     repopulated (use to suppress without unregistering).
    //   - rects = [..]  → consumer fires only when the event's cursor
    //                     position falls in ANY of the rects. Coords are
    //                     top-left origin global screen, same space as
    //                     `sd.windows.byId.frame`/`buttonFrames`.
    // The consume decision is synchronous in the daemon, so updates take
    // effect on the next event; no async lag. Used by windowscape's port
    // of fullscreen_ui.lua to gate leftMouseDown consume on whether the
    // cursor is over a native traffic-light button.
    setTapRects(callback, rects) {
      return request({ type: "events.setTapRects", callback, rects: rects ?? null });
    },
    // Register the handler for a manifest-declared eventtap callback name.
    // Replaces the `window.onTap_<name> = (e) => {...}` global-mutation
    // pattern; returns a disposer that clears the slot on dispose. The
    // daemon still dispatches via window.onTap_<name>, so legacy assignments
    // keep working untouched.
    //   sd.events.on("snapshotsScroll", (e) => handleScroll(e));
    on(name, fn) { return __registerSlotHandler("Tap", name, fn); }
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
    running: channel("apps", []),
    // Transition deltas: { added: [...], removed: [...], changed: [...] }.
    // Fires only when something actually changed (not the initial full list
    // — for that, subscribe to .running). Consumers that only care about
    // launches/quits don't have to diff the full list themselves.
    changed: channel("appsChanged"),
    launch(bundleId)          { return request({ type: "apps.launch", bundleId }); },
    focus(bundleId)           { return request({ type: "apps.focus",  bundleId }); },
    kill(bundleId, force)     { return request({ type: "apps.kill",   bundleId, force: !!force }); },
    // hide / unhide accept either a bundleId (string) or a pid (number).
    // The bundleId form goes through the bundle-id NSWorkspace lookup;
    // the pid form goes through NSRunningApplication(processIdentifier:).
    // unhide is pid-only — NSRunningApplication.unhide() needs a specific
    // process instance, and "unhide every running copy of a bundle" isn't
    // a coherent verb.
    hide(arg) {
      if (typeof arg === "number") return request({ type: "apps.hideByPid", pid: arg });
      return request({ type: "apps.hide", bundleId: arg });
    },
    unhide(pid)               { return request({ type: "apps.unhideByPid", pid }); },
    // Curated AX readers on a pid. Mirrors hs.application's menu /
    // findMenuItem / selectMenuItem / visibleWindows surface.
    //   const tree = await sd.apps.menu(pid);
    //   // → { title, role, children: [
    //   //     { title: "File", role: "AXMenuBarItem",
    //   //       children: [{ title: "New", role: "AXMenuItem",
    //   //                    enabled: true, shortcut: "⌘N" }, ...] }, ...] }
    //   await sd.apps.findMenuItem(pid, ["File", "Save As…"]);
    //   // → { title, role, enabled, marked? } | null
    //   await sd.apps.selectMenuItem(pid, ["File", "Save"]);
    //   // → boolean (true = AXPressAction succeeded)
    //   await sd.apps.visibleWindows(pid);
    //   // → [{ id, app, pid, title, frame, onscreen }, ...]  // filtered sd.windows.all, minimized dropped
    menu(pid)                  { return request({ type: "apps.menu", pid }); },
    findMenuItem(pid, path)    { return request({ type: "apps.findMenuItem", pid, path }); },
    selectMenuItem(pid, path)  { return request({ type: "apps.selectMenuItem", pid, path }); },
    visibleWindows(pid)        { return request({ type: "apps.visibleWindows", pid }); },
    // Per-pid window-set readers. Each returns CGWindowID(s) — chain into
    // sd.windows.byId.* (frame, title, focus, raise, snapshot, …) from JS.
    //   await sd.apps.focusedWindow(pid)  // → number | null  (AX focused)
    //   await sd.apps.mainWindow(pid)     // → number | null  (AX main)
    //   await sd.apps.allWindows(pid)     // → number[]       (all AX windows, includes minimized)
    // Mirrors hs.application:focusedWindow / :mainWindow / :allWindows.
    focusedWindow(pid)         { return request({ type: "apps.focusedWindow", pid }); },
    mainWindow(pid)            { return request({ type: "apps.mainWindow", pid }); },
    allWindows(pid)            { return request({ type: "apps.allWindows", pid }); },
    // Per-pid app state. Cheap NSWorkspace / NSRunningApplication reads —
    // no AX gate.
    //   await sd.apps.isFrontmost(pid)  // → boolean
    //   await sd.apps.isHidden(pid)     // → boolean
    isFrontmost(pid)           { return request({ type: "apps.isFrontmost", pid }); },
    isHidden(pid)              { return request({ type: "apps.isHidden", pid }); }
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
    // System-wide focused element — mirrors HS's
    // ax.systemWideElement():attributeValue("AXFocusedUIElement"). Use this
    // when the focused element may sit OUTSIDE the frontmost app (system
    // dialogs, popovers, menu bar). For ordinary text-input anchoring this
    // returns the same thing as focusedElement(); for cross-app focus cases
    // it's the HS-faithful choice.
    focusedElementSystemWide()        { return request({ type: "ax.focusedElementSystemWide" }); },
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
    dismiss() { return request({ type: "window.dismiss" }); },
    // Fade the entire panel (glass material + WebView) to `value` in [0, 1].
    // Out-of-range values are clamped. The first call permanently disables
    // the daemon's FirstPaintGate auto-reveal — once a stack takes manual
    // alpha control, the daemon stops setting alphaValue itself, so the
    // stack owns visibility from then on. Use this when CSS opacity on
    // body isn't enough (e.g. material: glass — the NSGlassEffectView
    // renders independently of WebView contentView alpha and stays visible
    // even when the body is opacity:0).
    setAlpha(value) { return request({ type: "window.setAlpha", value }); },
    // Reposition (and optionally resize) the panel at runtime. Coordinates
    // are in CG / AX convention (top-left origin) — matches what
    // sd.windows.focused.peek().frame and sd.ax.attribute(_, "AXFrame")
    // return. Width / height optional: omit to keep current dimensions.
    //
    //   sd.window.setFrame({ x: 100, y: 200 })                  // move only
    //   sd.window.setFrame({ x: 100, y: 200, w: 320, h: 320 })  // move + resize
    //
    // Used by stacks that anchor themselves per-invocation (Muse to the
    // AX-focused element) when the static manifest anchor isn't enough.
    setFrame(rect) {
      const r = rect || {};
      return request({ type: "window.setFrame", x: r.x, y: r.y, w: r.w, h: r.h });
    },
    // Dynamically toggle click-through. true = pass clicks through to the
    // layer beneath (desktop, system menubar). false = receive clicks
    // normally. Used by stacks that need per-region routing — most notably
    // the menubar "bar" stack, which polls sd.mouse and flips this as the
    // cursor crosses its item rects so the system menubar stays clickable
    // outside the bar's items.
    setClickThrough(value) { return request({ type: "window.setClickThrough", value: !!value }); },
    // Aggregator over setAlpha / setClickThrough / setFrame. Lets stacks
    // drive every runtime panel attribute from one place instead of
    // seeding via manifest then immediately overriding. Unspecified fields
    // are left untouched (no implicit reset).
    //
    //   sd.window.configure({ alpha: 0, clickThrough: true });
    //   sd.window.configure({ frame: { x, y, w, h }, alpha: 1 });
    //
    // Returns Promise.all of the inner RPCs; await if you need every
    // change visible before the next line runs.
    configure(spec) {
      const s = spec || {};
      const out = [];
      if (typeof s.alpha === "number") out.push(request({ type: "window.setAlpha", value: s.alpha }));
      if (s.clickThrough !== undefined) out.push(request({ type: "window.setClickThrough", value: !!s.clickThrough }));
      if (s.frame) {
        const r = s.frame;
        out.push(request({ type: "window.setFrame", x: r.x, y: r.y, w: r.w, h: r.h }));
      }
      return Promise.all(out);
    }
  },
  hotkey: {
    // Dynamically bind a Carbon hotkey from JS. Equivalent to the manifest
    // `hotkeys` block but works after the stack starts — for transient chords
    // like a Palette in verb mode or a chooser's number keys.
    //   const h = await sd.hotkey.bind("ctrl+alt+l", () => doThing());
    //   ...later...
    //   await sd.hotkey.unbind(h);
    // Options (skhd parity):
    //   { mode: "command" }                       // only fires while sd.hotkey.mode.current() === "command"
    //   { apps: ["com.apple.Safari"] }            // whitelist: only fires when listed bundleID is frontmost; "*" matches any
    //   { excludeApps: ["com.apple.Terminal"] }   // blacklist: suppress while listed bundleID is frontmost
    // apps + excludeApps compose (both must pass). Returns null if the spec doesn't parse. Per-stack: unload cancels all.
    bind(spec, fn, opts = {}) {
      // skhd composite-modifier aliases — expanded in JS so the daemon only
      // ever sees literal modifier names (cmd / ctrl / alt / shift / fn).
      // Whole-token match, case-insensitive, run before IPC.
      const expanded = String(spec).replace(/\bhyper\b/gi, "cmd+alt+ctrl+shift")
                                   .replace(/\bmeh\b/gi,   "alt+ctrl+shift");
      return registerHandler(hotkeyHandlers, {
        type: "hotkey.bind",
        spec: expanded,
        mode:        opts.mode        ?? null,
        apps:        opts.apps        ?? null,
        excludeApps: opts.excludeApps ?? null
      }, fn);
    },
    unbind(id) {
      return unregisterHandler(hotkeyHandlers, id, { type: "hotkey.unbind", id });
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
    },
    // Register the handler for a manifest-declared hotkey callback name.
    // Replaces the `window.onHotkey_<name> = fn` global-mutation pattern;
    // returns a disposer that clears the slot on unbind. The daemon still
    // dispatches via window.onHotkey_<name>, so legacy assignments keep
    // working untouched.
    //   sd.hotkey.on("toggleDebug", () => state.debug = !state.debug);
    on(name, fn) { return __registerSlotHandler("Hotkey", name, fn); }
  },
  // Generic NSDistributedNotificationCenter subscription. The same machinery
  // Caffeinate uses internally (com.apple.screenIsLocked, etc.) but exposed
  // to any stack. Permission: "broadcasts".
  //   const id = await sd.broadcasts.subscribe(
  //     "com.apple.screenIsLocked",
  //     (payload) => console.log("locked at", payload));
  //   ...later...
  //   await sd.broadcasts.unsubscribe(id);
  //
  // Verb is "subscribe" to match signals (sd.battery.subscribe(fn)). The old
  // names .observe / .unobserve are kept as aliases for back-compat; they
  // collided with the daemon-side Observer pattern (BatteryObserver etc.)
  // which is a poller, not a listener.
  broadcasts: {
    subscribe(name, fn) {
      return registerHandler(broadcastHandlers, { type: "broadcasts.observe", name }, fn);
    },
    unsubscribe(id) {
      return unregisterHandler(broadcastHandlers, id, { type: "broadcasts.unobserve", id });
    },
    // Back-compat aliases — prefer .subscribe / .unsubscribe in new code.
    observe(name, fn)  { return this.subscribe(name, fn); },
    unobserve(id)      { return this.unsubscribe(id); }
  },
  // Custom URL-scheme handlers. Register a callback for `<scheme>://...`
  // URLs that other apps open; the callback fires with the parsed URL +
  // query params each time a matching URL is routed to stackd. Backed by
  // NSAppleEventManager's GURL handler.
  //
  //   const h = await sd.urlhandler.register("myscheme", (event) => {
  //     console.log(event);
  //     // → { url: "myscheme://foo/bar?baz=1#x",
  //     //     scheme: "myscheme", host: "foo", path: "/bar",
  //     //     query: { baz: "1" }, fragment: "x" }
  //   });
  //   ...later...
  //   await h.unregister();
  //
  // Multi-value query keys collapse last-write-wins; re-parse `event.url`
  // with URLSearchParams if you need every occurrence.
  //
  // Important: macOS only routes `myscheme://...` to stackd if the daemon's
  // Info.plist declares the scheme under CFBundleURLTypes. During development
  // (running `.build/stackd` directly, no `.app` bundle) custom-scheme URLs
  // won't reach the handler at all — the API surface is wired and ready for
  // when stackd ships bundled. The standard `stackd://` scheme is handled
  // by URLSchemeHandler.swift and is independent of this API.
  //
  // Permission: "urlhandler".
  urlhandler: {
    async register(scheme, fn) {
      const id = await registerHandler(urlHandlerHandlers, {
        type: "urlhandler.register",
        scheme: String(scheme ?? "")
      }, fn);
      if (id == null) return null;
      return {
        id,
        unregister() {
          return unregisterHandler(urlHandlerHandlers, id, {
            type: "urlhandler.unregister", id
          });
        }
      };
    }
  },
  // WebKit overlay pinned to a target window the stack doesn't own. The
  // daemon hosts a borderless click-through NSPanel + WKWebView whose
  // frame tracks SLSGetWindowBounds(targetId) every vsync; inside that
  // WebView, the stack-supplied {html, css, js} renders normally. The
  // daemon pushes `window.sd.target = {x, y, w, h}` into the overlay's
  // WebView each tick (and fires a `sd:target` CustomEvent) so spec
  // authors can position their elements off the current target geometry.
  //
  //   const h = await sd.overlay.attach(targetId, {
  //     html: `<div class="border"></div>`,
  //     css:  `.border { position: absolute; inset: 1px;
  //                      border: 2px solid #7c8cff; border-radius: 16px;
  //                      pointer-events: none; }`,
  //     js:   `/* optional — runs inside the overlay's WebView */`
  //   });
  //   ...later...
  //   await h.detach();
  //
  // Inside the overlay's WebView, `window.sd.target = {x:0, y:0, w, h}`
  // is updated each vsync (x/y are relative to the panel's own origin —
  // always 0,0). Permission: "overlay".
  overlay: {
    async attach(targetId, spec) {
      const s = spec || {};
      const handleId = await request({
        type: "overlay.attach",
        targetId,
        html: s.html != null ? String(s.html) : "",
        css:  s.css  != null ? String(s.css)  : "",
        js:   s.js   != null ? String(s.js)   : ""
      });
      if (handleId == null) return null;
      return {
        id: handleId,
        // Move this overlay to a different target window without tearing
        // down the WKWebView. The vsync ticker repositions on the next
        // frame, and any pending eval() calls queued before navigation
        // finished still run on the same WebView. Use this for one-overlay-
        // follows-focus designs (overlay-border) where detach+attach would
        // race and leave duplicate panels on screen.
        setTarget(newTargetId) {
          return request({ type: "overlay.setTarget", id: handleId, targetId: newTargetId });
        },
        // Evaluate JS in the overlay's WebView. Pairs with setTarget to
        // refresh styling (color, radius, theme) when retargeting. The
        // overlay's WebView is otherwise opaque — there's no postMessage
        // channel from the host stack.
        eval(js) {
          return request({ type: "overlay.eval", id: handleId, js: String(js ?? "") });
        },
        detach() { return request({ type: "overlay.detach", id: handleId }); }
      };
    }
  },
  // Long-running HTTP server. Loopback-only by default; pass
  // bindHost: "0.0.0.0" to expose on the LAN. A single callback receives every
  // request and returns { status?, headers?, body?, bodyEncoding? }. The stack
  // owns route dispatch (string compare on req.path), CORS headers,
  // Content-Type, and static-asset lookup — the daemon is just listener +
  // parser + writer.
  //   const srv = await sd.httpserver.serve({ port: 7373 }, async (req) => {
  //     if (req.path === "/hello") {
  //       return { status: 200, headers: { "Content-Type": "text/plain" }, body: "hello" };
  //     }
  //     if (req.path === "/icon.png") {
  //       const b64 = await sd.fs.read("/path/to/icon.png", { encoding: "base64" });
  //       return { status: 200, headers: { "Content-Type": "image/png" },
  //                body: b64, bodyEncoding: "base64" };
  //     }
  //     return { status: 404, body: "not found" };
  //   });
  //   ...later...
  //   await srv.stop();
  // bodyEncoding: "base64" tells the daemon to decode `body` before writing
  // to the wire — use this for PNG / PDF / any binary payload. Omit it (or
  // pass any other value) and `body` is sent as a UTF-8 string.
  // Consumers: CloudPad (serves snapshot + bang surface to phones on the LAN);
  // any webhook receiver or local API dashboard stack.
  httpserver: {
    async serve(opts, callback) {
      const o = opts || {};
      if (typeof callback !== "function") return null;
      const id = await registerHandler(httpServers, {
        type: "httpserver.serve",
        port: o.port || 0,
        bindHost: o.bindHost || "127.0.0.1",
        bonjour: o.bonjour
      }, callback);
      if (id == null) return null;
      return {
        id,
        port: o.port,
        url: `http://${o.bindHost === "0.0.0.0" ? "localhost" : (o.bindHost || "127.0.0.1")}:${o.port}`,
        stop() { return unregisterHandler(httpServers, id, { type: "httpserver.stop", id }); }
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
  // Two shapes:
  //   sd.bang(name, detail)              — fire-and-forget emit (legacy, still supported)
  //   sd.bang.declare(name)              — typed registry: { emit, on } pair so
  //                                        producer and consumer reference the
  //                                        SAME declared handle. Typos surface
  //                                        as unpaired declarations StackDoctor
  //                                        can flag.
  // Both routes dispatch through the same `window.onBang_<slug>` slot, so
  // mixing styles in one daemon process works. Adoption is per-stack.
  // Generic slot-registration entry — `sd.handlers.register("Tap", "foo", fn)`
  // is equivalent to `sd.events.on("foo", fn)` / `sd.hotkey.on("foo", fn)`
  // depending on kind. Surface for any future slot the daemon adds; per-kind
  // sugar (sd.events.on, sd.hotkey.on) stays the discoverable path. Returns
  // a disposer.
  handlers: {
    register(kind, name, fn) { return __registerSlotHandler(kind, name, fn); }
  },
  bang: Object.assign(
    (name, detail) => request({ type: "bang", name, detail: detail || {} }),
    {
      declare(name) {
        const slug = __bangSlug(name);
        const dec = __ensureBangRouter(slug);
        return {
          name,
          emit(detail) { return request({ type: "bang", name, detail: detail || {} }); },
          on(fn) {
            dec.listeners.add(fn);
            return () => dec.listeners.delete(fn);
          }
        };
      }
    }
  ),
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
  //
  // Setter side: sd.caffeinate.assert({ type, reason? }) takes an IOPM wake
  // lock and returns a handle. Call handle.release() (or await it) when the
  // work is done — stack unload releases anything still outstanding.
  //
  //   const h = await sd.caffeinate.assert({ type: "display", reason: "exporting video" });
  //   try { await exportVideo(); } finally { await h.release(); }
  //
  // Types:
  //   "display"      — display + system stay awake (NoDisplaySleepAssertion).
  //                    Use for video export, screen capture, presenting.
  //   "system"       — system stays awake; display can dim/sleep on its own
  //                    timer (NoIdleSleepAssertion). Use for long-running
  //                    background work that doesn't need the screen lit.
  //   "userActivity" — advisory variant of system, bound to the user-idle
  //                    path (PreventUserIdleSystemSleep). Same intent as
  //                    "system" but lower-priority — yields to other power
  //                    policies (e.g. AC vs battery) more readily.
  //
  // Permission: "caffeinate".
  caffeinate: Object.assign(channel("caffeinate"), {
    async assert(spec) {
      const s = spec || {};
      // The IPC envelope's `type` is reserved for primitive dispatch
      // ("caffeinate.assert"); the assertion kind ("display"/"system"/
      // "userActivity") travels on `assertionType` and Bridge.swift reads
      // it back under that key.
      const id = await request({
        type:          "caffeinate.assert",
        assertionType: s.type,
        reason:        s.reason != null ? String(s.reason) : ""
      });
      if (id == null) return null;
      return {
        id,
        release() { return request({ type: "caffeinate.release", id }); }
      };
    }
  }),
  // Vsync-locked frame tick. Refresh rate matches the display (60 Hz on
  // standard, 120 Hz on ProMotion). Cheaper + smoother than rAF inside a
  // heavy WebView, and aligned to the compositor's flip cadence —
  // sd.overlay uses the same observer to reposition the overlay panel.
  //   sd.displayLink.subscribe(({ timestamp, frame, refreshRate }) => { ... })
  displayLink: channel("displayLink"),
  // System info (one-shot) + load signal (polled 2s):
  //   await sd.host.info()  → { hostname, os: {name,version,build}, locale,
  //                              arch, cpuCount, ramMB }
  //   sd.host.load          → { cpu: {user,system,idle,total},     // 0-1 fractions
  //                              idleSeconds,                       // since last HID
  //                              memoryMB: {used,free,wired},
  //                              memoryPressure,                    // "normal"|"warning"|"critical"
  //                              swap: {totalMB,usedMB},
  //                              gpu: {usagePercent} }              // Apple Silicon / iGPU
  //   await sd.host.diskIO() → [{ name, bytesRead, bytesWritten,
  //                                opsRead, opsWritten,
  //                                bytesReadPerSecond?, bytesWrittenPerSecond? }, ...]
  // First load tick fires ~2s after subscribe (CPU fractions need a prior
  // sample to diff against). idleSeconds resets to ~0 the instant the user
  // moves the mouse or types. gpu / swap / memoryPressure may be absent on
  // hardware where the underlying sysctl or IOAccelerator query fails — treat
  // each as optional in stack code.
  // diskIO() is pulled (not pushed) — call it on whatever cadence you want.
  // Per-second rates are only emitted from the SECOND call onward (the first
  // call seeds the per-device baseline). `name` is the BSD identifier
  // ("disk0", "disk1s2", ...). Stats.app-style IOBlockStorageDriver walk.
  // Tunable cadence — pass `{ interval }` (seconds) to slow this stack's
  // fanout for the channel:
  //   sd.host.load.subscribe(load => render(load), { interval: 10 });
  host: {
    info()   { return request({ type: "host.info" }); },
    diskIO() { return request({ type: "host.diskIO" }); },
    load:    channel("hostLoad")
  },
  // Mac internal sensors via IOHIDEventSystem (Apple silicon: per-die temps,
  // per-rail voltage/current, fan RPM). Polled at 2s. Intel SMC sensors deferred.
  //   sd.sensors → { temperatures: [{name,value,unit}, ...], voltages: [...],
  //                  currents: [...], fans: [{name, rpm}, ...] }
  // Tunable cadence — pass `{ interval }` (seconds) to slow this stack's
  // fanout:
  //   sd.sensors.subscribe(s => updateTempUI(s), { interval: 5 });
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
  // One-shot Spotlight via NSMetadataQuery. `predicate` is the raw
  // NSPredicate format string — kMDItem* attributes joined by AND / OR.
  //   await sd.spotlight.find({
  //     predicate: "kMDItemFSName LIKE[cd] '*.pdf'",
  //     scopes: ["/Users/me/Documents"],     // default: whole computer
  //     limit: 50                             // default: unbounded
  //   })
  //   // → [{ kMDItemFSName, kMDItemPath, kMDItemContentType,
  //   //      kMDItemFSContentChangeDate, kMDItemFSCreationDate,
  //   //      kMDItemFSSize }, ...]
  // Override `attributes` to fetch a different mdkit attribute set.
  // Predicate syntax: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Predicates/AdditionalChapters/Introduction.html
  // Dates are epoch-seconds Numbers; bad predicates will crash the daemon
  // (NSException isn't catchable from Swift) — test your predicate string.
  // Live variant — keeps an NSMetadataQuery alive and pushes the FULL
  // current result-set each time the Spotlight index notifies a change.
  // Same shape as find()'s return: an array of attribute dicts. First emit
  // lands after the initial gather finishes; subsequent emits ride
  // NSMetadataQueryDidUpdate. Stop the query when done.
  //   const q = sd.spotlight.subscribe({
  //     predicate: "kMDItemFSContentChangeDate > $time.today(-1)",
  //     scopes: ["/Users/me/Downloads"]
  //   });
  //   const unsub = q.subscribe(files => render(files));
  //   // ...later...
  //   unsub();        // stop receiving updates (JS-side only)
  //   await q.stop(); // tear down the underlying NSMetadataQuery
  // Mirrors sd.bonjour.browse(): same handle id + per-instance channel
  // ("spotlight:subscribe:<id>") + buffered-subscriber pattern.
  spotlight: {
    find(opts) {
      const o = opts || {};
      return request({
        type: "spotlight.find",
        predicate:  o.predicate,
        scopes:     o.scopes,
        attributes: o.attributes,
        limit:      o.limit
      });
    },
    subscribe(opts) {
      const o = opts || {};
      // The handle id arrives async, so subscribers attached before the
      // id resolves get buffered locally and re-bound to the synthesized
      // channel ("spotlight:subscribe:<id>") once we have it. After that,
      // subscribe() goes straight to the underlying channel signal.
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:       "spotlight.subscribe",
        predicate:  o.predicate,
        scopes:     o.scopes,
        attributes: o.attributes,
        limit:      o.limit
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("spotlight:subscribe:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          // Pre-bind unsubscribe: drop from the local set if the start
          // request hasn't resolved yet. Post-bind unsubscribes are
          // best-effort (the channel signal doesn't expose an unbind hook
          // once we lose the inner unsubscribe ref) — process-lifetime
          // channels mean the cost is one callback ref until stack unload.
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "spotlight.subscribe.stop", id });
        }
      };
    }
  },
  // Bonjour / mDNS — publish a service on the LAN, or browse for one.
  // Backed by Network.framework (NWListener + NWBrowser). On macOS 15+ the
  // first publish/browse triggers a Local Network privacy prompt; the
  // framework raises it — we don't preflight.
  //
  //   const ad = await sd.bonjour.publish({
  //     name: "My Stack",
  //     type: "_http._tcp",
  //     port: 7373,
  //     txt:  { path: "/", role: "primary" }   // optional
  //   });
  //   // ...later...
  //   await ad.stop();
  //
  //   const b = sd.bonjour.browse("_http._tcp");
  //   const unsub = b.subscribe(services => {
  //     // services = [{ name, type, host?, port?, txt }, ...]
  //     // host/port may be absent until a follow-up NWConnection resolves
  //     // the .service endpoint; subscribe yields the full set each time.
  //     render(services);
  //   });
  //   // ...later...
  //   unsub();          // stop receiving updates (JS-side only)
  //   await b.stop();   // tear down the underlying NWBrowser
  //
  // Pairs with sd.httpserver: publish your listener's port and another Mac's
  // stack can find it via browse(). Or browse `_ipp._tcp` for the office
  // printer, `_mqtt._tcp` for an MQTT broker, etc.
  // Permission: "bonjour".
  bonjour: {
    // Note on the wire shape: the IPC envelope's `type` key is reserved for
    // primitive dispatch ("bonjour.publish" / "bonjour.browse.start"), so
    // the bonjour service type ("_http._tcp", etc.) travels under
    // `serviceType`. Same workaround as caffeinate.assert/assertionType.
    async publish(opts) {
      const o = opts || {};
      const id = await request({
        type:        "bonjour.publish",
        name:        String(o.name ?? ""),
        serviceType: String(o.type ?? ""),
        port:        o.port | 0,
        txt:         o.txt || null
      });
      if (id == null) return null;
      return {
        id,
        stop() { return request({ type: "bonjour.publish.stop", id }); }
      };
    },
    browse(type) {
      // The handle id arrives async, so subscribers attached before the
      // id resolves get buffered locally and re-bound to the synthesized
      // channel ("bonjour:browse:<id>") once we have it. After that,
      // subscribe() goes straight to the underlying channel signal.
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:        "bonjour.browse.start",
        serviceType: String(type ?? "")
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("bonjour:browse:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          // Pre-bind unsubscribe: drop from the local set if the start
          // request hasn't resolved yet. Post-bind unsubscribes are
          // best-effort (the channel signal doesn't expose an unbind hook
          // once we lose the inner unsubscribe ref) — process-lifetime
          // channels mean the cost is one callback ref until stack unload.
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "bonjour.browse.stop", id });
        }
      };
    }
  },
  // Pending macOS software updates via `softwareupdate -l`. No TCC; the
  // list verb doesn't need escalation. The shell-out is slow (5-10s —
  // contacts Apple's update catalog), so results are cached process-wide
  // for ~6 hours. Pass `force: true` to refresh now.
  //   const updates = await sd.update.list()
  //   // → [{ label: "macOS Sonoma 14.5-23F79",
  //   //      title: "macOS Sonoma 14.5",
  //   //      version: "14.5",
  //   //      sizeKiB: 7159564,
  //   //      recommended: true,
  //   //      requiresRestart: true }, ...]
  // Empty array = no updates pending. `title`, `version`, `sizeKiB` may be
  // omitted if Apple's output line for that update lacked the field.
  update: {
    list(opts) {
      const o = opts || {};
      return request({
        type: "update.list",
        force: !!o.force,
        ttlSeconds: o.ttlSeconds
      });
    }
  },
  // QLThumbnailGenerator one-shot — same preview Finder/Quick Look render
  // for the file at `path` (PDF first page, video poster, audio waveform,
  // app icon, source-code thumbnail). No TCC; file accessibility is the
  // only gate.
  //   const t = await sd.thumbnails.generate({
  //     path: "~/Documents/report.pdf",
  //     width: 256, height: 256,    // points; pixels = size * scale
  //     scale: 2,                    // default: main display backing scale
  //     representation: "all",       // "all" | "thumbnail" | "icon" | "lowQualityThumbnail"
  //     format: "png",               // "png" (default) | "jpeg"
  //     quality: 0.85                // jpeg only
  //   })
  //   // → { dataURL, width, height, type }  or null
  // `type` echoes which QL pass produced the image — handy for telling
  // an icon fallback apart from a real thumbnail.
  thumbnails: {
    generate(opts) {
      const o = opts || {};
      return request({
        type: "thumbnails.generate",
        path:           String(o.path ?? ""),
        width:          o.width,
        height:         o.height,
        scale:          o.scale,
        representation: o.representation,
        format:         o.format,
        quality:        o.quality,
        timeoutSeconds: o.timeoutSeconds
      });
    }
  },
  // Calendar events via EventKit. First call to events()/createEvent()
  // triggers the Calendar TCC prompt (macOS 14+ asks for "Full Access" —
  // covers both reads + writes). reminders() triggers a SEPARATE Reminders
  // TCC prompt the first time it's called. Denial yields [] / null, never
  // throws.
  //   await sd.calendar.events({ from: nowSec, to: nowSec + 86400 })
  //   await sd.calendar.events({ from, to, calendarIds: ["UUID..."] })
  //   // → [{ identifier, title, start, end, allDay, calendar,
  //   //      location?, notes?, url? }, ...]
  //   await sd.calendar.list()
  //   // → [{ identifier, title, source, type, allowsModify, color? }, ...]
  //   await sd.calendar.reminders()
  //   await sd.calendar.reminders({ completed: false })   // only incomplete
  //   await sd.calendar.reminders({ completed: true })    // only completed
  //   await sd.calendar.reminders({ list: ["UUID..."] })  // specific list(s)
  //   // → [{ identifier, title, priority, completed, list,
  //   //      due?, notes? }, ...]
  //   const id = await sd.calendar.createEvent({
  //     calendarId: null,                  // null = default calendar
  //     title: "Standup", start: nowSec, end: nowSec + 1800,
  //     location: "Room 4", notes: "...", allDay: false
  //   });
  //   // → newEventId | null on failure
  //   sd.calendar.observe.subscribe(() => refetch());
  //   // Fires on every store change (this daemon, Calendar.app, Reminders,
  //   // MDM sync, …). Payload is `{ ts: epoch }` — re-fetch on signal.
  // Times are UNIX epoch seconds (Number). Reminders WRITE (createReminder)
  // is not yet shipped.
  calendar: {
    events(opts) {
      const o = opts || {};
      return request({
        type: "calendar.events",
        from: o.from, to: o.to,
        calendarIds: o.calendarIds
      });
    },
    list() { return request({ type: "calendar.list" }); },
    reminders(opts) {
      const o = opts || {};
      return request({
        type:      "calendar.reminders",
        list:      o.list,
        completed: o.completed
      });
    },
    createEvent(opts) {
      const o = opts || {};
      return request({
        type:       "calendar.createEvent",
        calendarId: o.calendarId,
        title:      String(o.title ?? ""),
        start:      o.start,
        end:        o.end,
        location:   o.location,
        notes:      o.notes,
        allDay:     !!o.allDay
      });
    },
    // Subscribable signal. Fires every time EventKit posts
    // EKEventStoreChanged — any app adding/editing/deleting an event or
    // reminder triggers it. Payload is a fresh `{ ts }` so the signal's
    // dedupe doesn't suppress repeat changes; subscribers re-fetch.
    //   const unsub = sd.calendar.observe.subscribe(() => refetch());
    //   // later: unsub();
    observe: channel("calendarChanged")
  },
  // "Is anything capturing my screen / mic / camera right now?" — cross-
  // references the live-capture signals macOS exposes through public APIs.
  //   const r = await sd.privacy.recording();
  //   // → { screen: [], camera: [{ device, id, inUse: true }, ...],
  //   //                  microphone: [{ device, id, inUse: true }, ...] }
  //   sd.privacy.observe.subscribe(({ camera, microphone }) => {
  //     // Fires every 2s when the active set changes (diff-pushed —
  //     // steady-state "nothing recording" doesn't refire).
  //   });
  // v1 limitations (documented):
  //  - `screen` is always [] — accurate process attribution for screen
  //    capture needs private SPI (out of scope for v1). Future v2 can
  //    populate the array without breaking the shape contract.
  //  - Camera / mic entries don't include `app` / `pid` — AVCaptureDevice
  //    + CoreAudio don't expose the owning process; resolving it would
  //    need fragile lsof / /dev walks. v1 surfaces the per-device boolean
  //    only. v2 may add app attribution once a stable signal exists.
  // Reading does NOT trigger camera / microphone TCC prompts (no stream
  // is opened — pure property reads on the device enumeration).
  privacy: {
    recording() { return request({ type: "privacy.recording" }); },
    observe: channel("privacy")
  },
  // Paired Bluetooth peripherals via IOBluetooth. Triggers the Bluetooth
  // TCC prompt on first use.
  //   const devices = await sd.bluetooth.paired();
  //   // → [{ address, connected, name?, classOfDevice?, services?:
  //   //      ["Hands-Free Audio Gateway", "A2DP", ...] }, ...]
  // `services` differentiates AirPods (audio sink + handset) from generic
  // controllers without you having to decode classOfDevice bits.
  // Battery levels (AirPods left/right/case, mouse %) are not yet exposed —
  // those need per-device-class private SPI (separate follow-up).
  bluetooth: {
    paired() { return request({ type: "bluetooth.paired" }); }
  },
  // Text-to-speech via AVSpeechSynthesizer (no TCC, no microphone) plus
  // speech-to-text via SFSpeechRecognizer + AVAudioEngine. STT triggers
  // TWO TCC prompts on first listen():
  //   - Microphone           (NSMicrophoneUsageDescription)
  //   - Speech Recognition   (NSSpeechRecognitionUsageDescription)
  //
  //   sd.speech.speak("hello");
  //   sd.speech.speak("hola", { voice: "es-ES" });            // by locale
  //   sd.speech.speak("text", { voice: "com.apple.voice...", rate: 0.5,
  //                             pitch: 1.1, volume: 0.8 });
  //   sd.speech.stop();                  // immediate
  //   sd.speech.stop({ boundary: "word" }); // wait for current word
  //   const voices = await sd.speech.voices(); // installed voices
  // rate is 0..1 (0.5 ≈ natural), pitch 0.5..2.0, volume 0..1.
  //
  //   const locales = await sd.speech.locales();   // BCP-47 strings
  //
  //   const ear = sd.speech.listen({ locale: "en-US" });
  //   ear.subscribe(({ text, isFinal, segments, error }) => {
  //     if (error) console.warn("speech listen failed:", error);
  //     render(text);                              // partials stream in
  //     if (isFinal) console.log("final:", text);  // recognizer stopped
  //   });
  //   // ...later, to stop early:
  //   await ear.stop();
  //
  // Pass { requireOnDevice: true } to force local-only recognition (audio
  // never leaves the device). Not every locale supports on-device — listen()
  // fires once with { error: "on-device recognition not supported…" } when
  // it doesn't. sd.speech.listen.cancel() stops every active listener
  // owned by this stack in one call (panic-stop shortcut).
  speech: (() => {
    // listen() returns a handle synchronously; the underlying id arrives
    // async (the request() round-trip), so subscribers attached before the
    // id resolves get buffered locally and re-bound to the synthesized
    // channel ("speech:listen:<id>") once we have it. Mirrors the
    // sd.bonjour.browse pattern exactly.
    const listen = (opts) => {
      const o = opts || {};
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:            "speech.listen.start",
        locale:          o.locale,
        requireOnDevice: !!o.requireOnDevice
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("speech:listen:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          // Pre-bind unsubscribe: drop from the local set if the start
          // request hasn't resolved yet. Post-bind unsubscribes are
          // best-effort (process-lifetime channels — same trade-off as
          // sd.bonjour.browse).
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "speech.listen.stop", id });
        }
      };
    };
    // Convenience hung off listen() itself — `sd.speech.listen.cancel()`
    // tears down every active listener owned by this stack at once.
    listen.cancel = () => request({ type: "speech.listen.cancel" });
    return {
      speak(text, opts) {
        const o = opts || {};
        return request({
          type: "speech.speak",
          text:   String(text ?? ""),
          voice:  o.voice,
          rate:   o.rate,
          pitch:  o.pitch,
          volume: o.volume
        });
      },
      stop(opts) {
        const o = opts || {};
        return request({ type: "speech.stop", boundary: o.boundary || "immediate" });
      },
      voices()  { return request({ type: "speech.voices" }); },
      locales() { return request({ type: "speech.locales" }); },
      listen
    };
  })(),
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
    // Joint positions are normalized 0..1, top-left origin. Every joint
    // Vision reports is included — including low-confidence ones — so
    // stacks pick their own threshold:
    //   const usable = Object.fromEntries(
    //     Object.entries(body.joints).filter(([_, j]) => j.confidence >= 0.1));
    // Multiple bodies per frame. Each named joint: nose, leftEye, rightEye,
    // leftEar, rightEar, leftShoulder, rightShoulder, neck, leftElbow,
    // rightElbow, leftWrist, rightWrist, leftHip, rightHip, root, leftKnee,
    // rightKnee, leftAnkle, rightAnkle.
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
  usb: channel("usb", []),
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
  //
  // .frame(opts) is the one-shot capture and the first call that DOES trigger
  // the Camera TCC prompt. Pairs with sd.vision.* — pipe the dataURL
  // straight in for live face/pose/subject extraction.
  //   await sd.camera.frame()
  //   await sd.camera.frame({ deviceId, format: "png" })
  //   await sd.camera.frame({ format: "jpeg", quality: 0.7, timeoutSeconds: 5 })
  //   // → { dataURL: "data:image/jpeg;base64,...", width, height }  (or null)
  //
  // .stream(opts) keeps an AVCaptureSession warm and pushes one frame per
  // tick at the requested fps (default 10, capped at 60). The camera LED
  // stays on for the lifetime of the stream — stop() turns it back off.
  // Same handle-id + subscribe + stop shape as sd.bonjour.browse so a
  // pre-resolve subscriber gets buffered until the channel exists.
  //   const s = sd.camera.stream({ fps: 10 });
  //   const unsub = s.subscribe(({ dataURL, width, height, ts }) => {
  //     img.src = dataURL;
  //   });
  //   // ...later...
  //   unsub();          // stop receiving locally
  //   await s.stop();   // tear the AVCaptureSession down (LED off)
  camera: Object.assign(channel("camera", []), {
    frame(opts) {
      const o = opts || {};
      return request({
        type: "camera.frame",
        deviceId:       o.deviceId,
        format:         o.format || "jpeg",
        quality:        o.quality,
        timeoutSeconds: o.timeoutSeconds
      });
    },
    stream(opts) {
      // Mirror sd.bonjour.browse: the handle id resolves async, so any
      // subscribers attached before the channel exists get buffered locally
      // and re-bound to the synthesized channel ("camera:stream:<id>") once
      // we have it. Post-resolve subscribe() goes straight through.
      const o = opts || {};
      const localSubs = new Set();
      let realCh = null;
      let realId = null;
      let stopped = false;
      const start = request({
        type:     "camera.stream.start",
        deviceId: o.deviceId,
        format:   o.format || "jpeg",
        quality:  o.quality,
        fps:      o.fps
      }).then((id) => {
        if (id == null || stopped) return null;
        realId = id;
        realCh = channel("camera:stream:" + id);
        for (const fn of localSubs) realCh.subscribe(fn);
        localSubs.clear();
        return id;
      });
      return {
        get id() { return realId; },
        subscribe(fn) {
          if (realCh) return realCh.subscribe(fn);
          localSubs.add(fn);
          return () => { localSubs.delete(fn); };
        },
        async stop() {
          stopped = true;
          const id = await start;
          if (id == null) return false;
          return request({ type: "camera.stream.stop", id });
        }
      };
    }
  }),
  spaces: {
    all: channel("spaces", []),
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
// Signals fall through to their payload via Proxy (see signal() at top of
// file), so `{{ sd.battery.percent }}` reads `.value.percent` directly — no
// `.value` ceremony needed. Before the first sample, array channels
// (windows.all, display.all, apps.running, spaces.all, usb, camera) default
// to `[]`; object channels return `undefined` for unknown keys. Either way,
// no throw — the expression renders empty until the first real sample.
//
// Limitations:
//   - Dependency tracking is regex-based: `{{ sd.battery.percent }}` finds
//     `sd.battery` in the source and subscribes. `const b = sd.battery;
//     b.percent` won't track because the regex never sees the alias. For
//     dynamic usage, drop down to `<script>` + `sd.bind`.
//   - <script> and <style> contents are skipped — they're not display surface.

// Lookup of every signal exposed on `sd.*` that templates can auto-subscribe
// to. Path strings match what the expression author writes (e.g.
// "windows.focused" for `{{ sd.windows.focused.title }}`). Longer paths are
// matched first so "windows.focused" wins over "windows".
//
// The list itself is owned daemon-side in `Sources/Channels.swift` and
// injected into the page as `window.__sd_channels` at document start
// (BEFORE this module loads). That single source of truth also drives the
// Swift-side `Bridge.replayState()` snapshot replay — adding a new channel
// is a one-place edit in Channels.swift; both sides pick it up. Pre-2026-06-04
// these two tables drifted whenever a primitive author touched one and
// forgot the other.
//
// Resolving each jsPath to its `sd.<x>.<y>` signal walks the dotted path at
// module-load time. A path that doesn't resolve is dropped (logs once) —
// usually means the channel was registered Swift-side but the JS API hasn't
// shipped its public `sd.foo` surface yet.
function __sdResolvePath(root, path) {
  const parts = path.split(".");
  let cur = root;
  for (const p of parts) {
    if (cur == null) return undefined;
    cur = cur[p];
  }
  return cur;
}

const __sdSignalPaths = (() => {
  const out = Object.create(null);
  const channels = (typeof window !== "undefined" && window.__sd_channels) || [];
  if (!channels.length) {
    console.warn("[stackd] window.__sd_channels missing — template engine dependency tracking disabled");
    return out;
  }
  for (const ch of channels) {
    if (!ch || !ch.jsPath) continue;
    const sig = __sdResolvePath(sd, ch.jsPath);
    if (sig == null) {
      console.warn("[stackd] channel registered without JS surface:", ch.jsPath);
      continue;
    }
    out[ch.jsPath] = sig;
  }
  return out;
})();

// Sort once, longer-first, so "windows.focused" matches before "windows" —
// otherwise the shorter prefix would always win and the longer path's signal
// would never get subscribed.
const __sdSignalPathsSorted = Object.keys(__sdSignalPaths)
  .sort((a, b) => b.length - a.length);

function __sdCompilePlaceholder(expr) {
  // Compile with (sd, item, index) signature. Non-loop placeholders just
  // don't reference item/index — bound to undefined when called outside a
  // sd-each context. Lets the same compiled fn work in both modes.
  let fn;
  try {
    fn = new Function("sd", "item", "index", "return (" + expr + ");");
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

function __sdEvalWithScope(compiled, item, index) {
  try {
    const v = compiled.fn(sd, item, index);
    return v == null ? "" : String(v);
  } catch (e) {
    return "";
  }
}

function __sdEvalPlaceholder(compiled) {
  // The signal Proxy fall-through means missing payload keys return
  // `undefined` (or `[]` for array-defaulted channels), not throw — so this
  // try/catch is now belt-and-suspenders for genuine expression errors
  // (TypeError calling a non-function, RangeError on stringify, etc.), not
  // the common null-payload-on-first-read case it was originally written for.
  return __sdEvalWithScope(compiled, undefined, undefined);
}

// Wire an applyFn to a set of dependent signals: paint once, subscribe each
// dep, register every unsub with __sdBindUnsubs so stack unload tears them
// down. Used by all four template paths (text nodes, attributes, sd-each,
// sd-if) — each supplies its own applyFn (DOM write strategies differ) but
// the subscription + cleanup plumbing is identical.
function __sdSubscribeAll(deps, applyFn) {
  applyFn();
  for (const sig of deps) {
    const unsub = sig.subscribe(applyFn);
    __sdBindUnsubs.add(unsub);
  }
}

// Scan a raw string for `{{ … }}` placeholders. Returns null when no
// placeholders are present, otherwise:
//   parts:  alternating literal-string / null slots — concat by replacing
//           each null with the eval of slots[slotIdx++].
//   slots:  compiled placeholder objects, one per { fn, deps }.
//   deps:   union of all slot deps (the set you subscribe to).
// Shared between __sdProcessAttribute (single-attr concat) and
// __sdProcessEachElement (per-text-or-attribute concat inside a clone).
function __sdScanPlaceholders(raw) {
  const re = /\{\{([\s\S]+?)\}\}/g;
  const parts = [];
  const slots = [];
  const deps = new Set();
  let lastIndex = 0;
  let m;
  while ((m = re.exec(raw)) !== null) {
    parts.push(raw.slice(lastIndex, m.index));
    const c = __sdCompilePlaceholder(m[1]);
    slots.push(c);
    parts.push(null);
    for (const d of c.deps) deps.add(d);
    lastIndex = m.index + m[0].length;
  }
  if (slots.length === 0) return null;
  parts.push(raw.slice(lastIndex));
  return { parts, slots, deps };
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
    __sdSubscribeAll(compiled.deps, () => {
      slot.textContent = __sdEvalPlaceholder(compiled);
    });
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
  // parts[i] is either a literal string or null (meaning "splice in
  // slots[slotIdx++]"). Cheap concat on every fire.
  const scanned = __sdScanPlaceholders(raw);
  if (!scanned) return;
  const { parts, slots, deps } = scanned;
  __sdSubscribeAll(deps, () => {
    let out = "";
    let slotIdx = 0;
    for (const p of parts) out += p === null ? __sdEvalPlaceholder(slots[slotIdx++]) : p;
    el.setAttribute(attrName, out);
  });
}

// ── sd-each list rendering ─────────────────────────────────────────────────
// `<li sd-each="sd.camera">{{ item.name }} ({{ index }})</li>` clones the
// element once per array item. `item` and `index` are bound inside any
// `{{ … }}` (text content or attributes) on the element or its descendants.
//
// Reconciliation modes:
//   - WITHOUT `sd-key`: full re-render on every signal fire — every active
//     clone removed, all new clones inserted. Cheap for short stable lists
//     (cameras, displays, USB, focused-app windows). The historical default.
//   - WITH `sd-key="<expr>"`: keyed reconciliation. The expression is
//     evaluated per item with `item` + `index` in scope; matching keys reuse
//     the existing DOM node (text/attribute slots re-applied), missing keys
//     are removed, new keys are cloned. DOM-stable: focus, scroll, in-flight
//     animations, and IME composition survive list updates. Use when the
//     list size is significant (`sd.windows.all`, ~50 entries) or when DOM
//     state matters across pushes.
//
// Limitations (v1):
//   - Nested sd-each not supported; an inner loop is silently ignored with a
//     console.warn. Compose a separate stack or drop down to JS.
//   - sd-if on the same element as sd-each is ignored (warn). Filter inside the
//     each expression instead: `sd-each="(sd.x || []).filter(…)"`.
//   - sd-if INSIDE a sd-each subtree is not honored per-clone — the each's
//     clones don't re-run sd-if compilation. Use a `{{ cond ? … : '' }}`
//     placeholder for per-item conditionals.
//   - sd-key MUST produce primitive keys (string/number/bool). Object keys
//     short-circuit to unkeyed behavior with a console.warn.

function __sdProcessEachElement(el) {
  const expr = el.getAttribute("sd-each");
  const sourceCompiled = __sdCompilePlaceholder(expr);
  const keyExprRaw = el.getAttribute("sd-key");
  const keyCompiled = keyExprRaw ? __sdCompilePlaceholder(keyExprRaw) : null;
  const anchor = document.createComment(" sd-each:" + expr + " ");
  el.parentNode.insertBefore(anchor, el);
  el.remove();
  el.removeAttribute("sd-each");
  if (keyExprRaw) el.removeAttribute("sd-key");

  // Pre-scan template (the detached `el`) for `{{ … }}` in text + attributes.
  // Record paths so we can re-locate each slot in a fresh clone without
  // re-scanning. Path is an array of childNodes-indices from the template root.
  const textOps = [];
  const attrOps = [];
  const allDeps = new Set(sourceCompiled.deps);
  const SKIP_TAGS = new Set(["SCRIPT", "STYLE"]);

  function scanPlaceholders(raw) {
    const got = __sdScanPlaceholders(raw);
    if (!got) return null;
    for (const d of got.deps) allDeps.add(d);
    return got;
  }

  function scan(node, path) {
    if (node.nodeType === 3) { // TEXT
      const got = scanPlaceholders(node.nodeValue);
      if (got) textOps.push({ path, parts: got.parts, slots: got.slots });
      return;
    }
    if (node.nodeType !== 1) return;
    if (SKIP_TAGS.has(node.nodeName)) return;
    // Nested sd-each: don't recurse; v1 limitation.
    if (node !== el && node.hasAttribute && node.hasAttribute("sd-each")) {
      console.warn("[stackd] nested sd-each not supported; ignoring inner loop on", node.nodeName);
      return;
    }
    for (const attr of Array.from(node.attributes)) {
      if (attr.name === "sd-each") continue;
      const got = scanPlaceholders(attr.value);
      if (got) attrOps.push({ path, attrName: attr.name, parts: got.parts, slots: got.slots });
    }
    for (let i = 0; i < node.childNodes.length; i++) {
      scan(node.childNodes[i], path.concat([i]));
    }
  }
  scan(el, []);

  function findByPath(root, path) {
    let n = root;
    for (const i of path) {
      if (!n || !n.childNodes) return null;
      n = n.childNodes[i];
    }
    return n;
  }

  function applyParts(parts, slots, item, index) {
    let out = "";
    let slotIdx = 0;
    for (const p of parts) {
      if (p === null) { out += __sdEvalWithScope(slots[slotIdx], item, index); slotIdx++; }
      else            { out += p; }
    }
    return out;
  }

  let active = [];                  // ordered DOM nodes currently rendered
  let activeKeys = [];              // parallel array of keys (or null if unkeyed)

  // Build or update a clone in place: re-apply every text + attribute slot
  // against the current `item` / `index`. Returns the node (possibly the
  // input one in the keyed-reuse case).
  function applyTemplateOps(node, item, index) {
    for (const op of textOps) {
      const target = findByPath(node, op.path);
      if (!target || target.nodeType !== 3) continue;
      target.nodeValue = applyParts(op.parts, op.slots, item, index);
    }
    for (const op of attrOps) {
      const target = findByPath(node, op.path);
      if (!target || target.nodeType !== 1) continue;
      target.setAttribute(op.attrName, applyParts(op.parts, op.slots, item, index));
    }
    return node;
  }

  function evalKey(item, index) {
    let k;
    try { k = keyCompiled.fn(sd, item, index); } catch (e) { k = undefined; }
    const t = typeof k;
    if (t === "string" || t === "number" || t === "boolean") return k;
    // Non-primitive keys (objects, null, undefined) can't be Map keys
    // reliably — short-circuit. Warn once per render cycle; the caller's
    // unkeyed branch handles the actual rendering.
    if (!evalKey._warned) {
      console.warn("[stackd] sd-each: sd-key produced non-primitive value; falling back to unkeyed render");
      evalKey._warned = true;
    }
    return undefined;
  }

  function renderUnkeyed(arr) {
    for (const n of active) n.remove();
    active = [];
    activeKeys = [];
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      const clone = applyTemplateOps(el.cloneNode(true), item, i);
      anchor.parentNode.insertBefore(clone, anchor.nextSibling);
      active.push(clone);
    }
  }

  function renderKeyed(arr) {
    // Index existing clones by their key for O(n) reuse lookup.
    const byKey = new Map();
    for (let i = 0; i < active.length; i++) {
      const k = activeKeys[i];
      if (k !== undefined) byKey.set(k, active[i]);
    }
    // First pass: collect keys, fall back to unkeyed if any key is bad.
    const keys = new Array(arr.length);
    for (let i = 0; i < arr.length; i++) {
      const k = evalKey(arr[i], i);
      if (k === undefined) { renderUnkeyed(arr); return; }
      keys[i] = k;
    }
    // Second pass: walk the new array in order; reuse existing nodes
    // where keys match (re-applying slot content), clone for new keys.
    // Insertion cursor starts at anchor — each placed node becomes the
    // new cursor so order matches `arr`.
    const newActive = new Array(arr.length);
    const reused = new Set();
    let cursor = anchor;
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      const k = keys[i];
      let node = byKey.get(k);
      if (node) {
        reused.add(node);
        applyTemplateOps(node, item, i);
        // Move into position only if not already adjacent — preserves
        // focus / scroll / animation state when order is stable.
        if (cursor.nextSibling !== node) {
          anchor.parentNode.insertBefore(node, cursor.nextSibling);
        }
      } else {
        node = applyTemplateOps(el.cloneNode(true), item, i);
        anchor.parentNode.insertBefore(node, cursor.nextSibling);
      }
      cursor = node;
      newActive[i] = node;
    }
    // Drop any active nodes that aren't part of the new list.
    for (const n of active) {
      if (!reused.has(n)) n.remove();
    }
    active = newActive;
    activeKeys = keys;
  }

  function render() {
    evalKey._warned = false;
    let arr;
    try { arr = sourceCompiled.fn(sd, undefined, undefined); } catch (e) { arr = null; }
    if (!Array.isArray(arr)) {
      for (const n of active) n.remove();
      active = [];
      activeKeys = [];
      return;
    }
    if (keyCompiled) renderKeyed(arr);
    else             renderUnkeyed(arr);
  }

  __sdSubscribeAll(allDeps, render);
}

// ── sd-if conditional rendering ────────────────────────────────────────────
// `<li sd-if="!sd.camera || sd.camera.length === 0">no cameras</li>` removes
// the element from the DOM when the expression is falsy, re-attaches it when
// truthy. Expression is re-evaluated on every signal fire whose channel it
// references (same regex-based dep detection as templates). The element keeps
// its compiled `{{ … }}` subscriptions across toggles — when detached, those
// fire harmlessly into a disconnected DOM; on re-attach the subtree already
// reflects current state.
//
// Setup runs BEFORE the text/attr walks so the anchor is in place, but
// detachment is deferred until AFTER those walks — that lets the regular
// placeholder compilation visit the (still-attached) subtree, so a falsy-at-
// load-time element still has its internal `{{ }}` bindings wired up for when
// it becomes truthy later.
function __sdSetupIfElement(el) {
  const expr = el.getAttribute("sd-if");
  el.removeAttribute("sd-if");
  const compiled = __sdCompilePlaceholder(expr);
  const anchor = document.createComment(" sd-if:" + expr + " ");
  el.parentNode.insertBefore(anchor, el);

  function evalTruthy() {
    try { return !!compiled.fn(sd, undefined, undefined); }
    catch (e) { return false; }
  }
  function render() {
    const truthy = evalTruthy();
    if (truthy && !el.isConnected) {
      anchor.parentNode.insertBefore(el, anchor.nextSibling);
    } else if (!truthy && el.isConnected) {
      el.remove();
    }
  }
  return { render, deps: compiled.deps };
}

function __sdCompileTemplates(root) {
  const SKIP = new Set(["SCRIPT", "STYLE"]);
  const PROBE = /\{\{[\s\S]+?\}\}/;

  // sd-each first — each loop removes its template from the live DOM and
  // replaces it with a comment anchor. Doing this before the text/attr walks
  // keeps those walks from seeing — and per-placeholder-subscribing —
  // anything inside loop bodies (which manage their own subscriptions and
  // need `item`/`index` in scope).
  const eachEls = [];
  const eachWalker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let eachEl;
  while ((eachEl = eachWalker.nextNode())) {
    if (SKIP.has(eachEl.nodeName)) continue;
    if (eachEl.hasAttribute("sd-each")) eachEls.push(eachEl);
  }
  for (const e of eachEls) {
    // Skip elements that were detached by an outer sd-each that already
    // processed them (nested case — warned about in __sdProcessEachElement).
    if (!e.isConnected) continue;
    if (e.hasAttribute("sd-if")) {
      console.warn("[stackd] sd-if on a sd-each element is ignored; filter inside the each expression instead");
      e.removeAttribute("sd-if");
    }
    __sdProcessEachElement(e);
  }

  // sd-if setup pass — installs comment anchors so structure is final before
  // the text/attr walks, but defers initial detachment until those walks have
  // had a chance to compile placeholders inside the subtree.
  const ifJobs = [];
  const ifWalker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
  let ifEl;
  while ((ifEl = ifWalker.nextNode())) {
    if (SKIP.has(ifEl.nodeName)) continue;
    if (ifEl.hasAttribute("sd-if")) ifJobs.push(ifEl);
  }
  const ifSetups = [];
  for (const e of ifJobs) {
    if (!e.isConnected) continue;
    ifSetups.push(__sdSetupIfElement(e));
  }

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

  // sd-if initial eval + dep subscription. Runs last so the subtree's
  // placeholders are compiled (and live-subscribed) before the first
  // detachment.
  for (const { render, deps } of ifSetups) __sdSubscribeAll(deps, render);
}

// Guard against double-compilation if an explicit `import { sd }` in a stack
// races with the auto-injected runtime loader. ES modules dedup by URL so
// the body only runs once anyway — guard is belt-and-suspenders.
//
// Deferred via setTimeout(0) after DOMContentLoaded so any user
// `<script type="module">` body that defines helpers (e.g. `window.icon = …`
// for templates to call) has finished executing before the template walk
// starts. Adds <1ms perceptible delay; eliminates a fragile race.
if (!window.__sd_templates_compiled) {
  window.__sd_templates_compiled = true;
  const compile = () => __sdCompileTemplates(document);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => setTimeout(compile, 0));
  } else {
    setTimeout(compile, 0);
  }
}

// Handshake: tell native we're ready so it can replay buffered state.
try {
  window.webkit.messageHandlers.sd.postMessage({ type: "ready" });
} catch (e) {
  console.error("ready handshake failed", String(e));
}
