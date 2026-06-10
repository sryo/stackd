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
function __ensureBangRouter(slug, originalName) {
  let dec = bangDeclarations.get(slug);
  if (dec) return dec;
  dec = { listeners: new Set() };
  bangDeclarations.set(slug, dec);
  // Tell the daemon this stack also handles `originalName` so dispatch
  // reaches us — no manifest `handles` entry required. The RPC is
  // fire-and-forget; the daemon's `bang.handle` primitive is idempotent
  // and ungated. originalName falls back to the slug if the caller
  // didn't pass one (rare back-compat path).
  request({ type: "bang.handle", name: originalName || slug });
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

export const sd = {};
