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
  battery:    channel("battery"),
  mouse:      channel("mouse"),
  appearance: channel("appearance"),
  app:        { frontmost: channel("frontApp") },
  windows:    { focused:   channel("focusedWindow") },
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
    }
  },
  menubar: {
    // Reference-counted system menu-bar visibility.
    // Multiple stacks can suppress; the bar reappears only once every
    // suppressor has called restore().
    suppress() { return request({ type: "menubar.suppress" }); },
    restore()  { return request({ type: "menubar.restore"  }); }
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
  events: {
    // Synthesize input. Note: scroll/click also fire your own eventtap
    // handlers if you have any registered. Use with care.
    type(text)            { return request({ type: "events.type", value: text }); },
    key(spec)             { return request({ type: "events.key",  spec }); },
    scroll(dx, dy)        { return request({ type: "events.scroll", dx, dy }); },
    click(x, y, button)   { return request({ type: "events.click", x, y, button: button || "left" }); }
  }
};

// Handshake: tell native we're ready so it can replay buffered state.
try {
  window.webkit.messageHandlers.sd.postMessage({ type: "ready" });
} catch (e) {
  console.error("ready handshake failed", String(e));
}
