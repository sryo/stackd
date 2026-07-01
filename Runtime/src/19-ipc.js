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
sd.broadcasts = {
    subscribe(name, fn) {
      return registerHandler(broadcastHandlers, { type: "broadcasts.observe", name }, fn);
    },
    unsubscribe(id) {
      return unregisterHandler(broadcastHandlers, id, { type: "broadcasts.unobserve", id });
    },
    // Back-compat aliases — prefer .subscribe / .unsubscribe in new code.
    observe(name, fn)  { return this.subscribe(name, fn); },
    unobserve(id)      { return this.unsubscribe(id); }
  };
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
sd.urlhandler = {
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
  };
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
sd.overlay = {
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
    },
    // Free-region overlay: a click-through panel the daemon draws at an
    // absolute GLOBAL screen rect (top-left, spanning all displays) — not
    // tracking any window. The daemon places it on whichever display contains
    // the rect, so a stack on display:"primary" can still render UI over a
    // window on another display. Returns a handle; the panel sits where put
    // until setFrame() / remove(). Permission: "overlay".
    //
    //   const p = await sd.overlay.region({
    //     rect: { x, y, w, h },          // global screen coords
    //     html: `<div class="ring"></div>`,
    //     css:  `.ring { position:absolute; inset:0; border:8px solid #1a4de6;
    //                    border-radius:16px; pointer-events:none; }`
    //   });
    //   p.setFrame({ x, y, w, h });      // re-place
    //   p.remove();
    async region(spec) {
      const s = spec || {};
      const r = s.rect || {};
      const handleId = await request({
        type: "overlay.region.create",
        rect: { x: +r.x || 0, y: +r.y || 0, w: +r.w || 0, h: +r.h || 0 },
        html: s.html != null ? String(s.html) : "",
        css:  s.css  != null ? String(s.css)  : ""
      });
      if (handleId == null) return null;
      return {
        id: handleId,
        setFrame(rect) {
          const q = rect || {};
          return request({ type: "overlay.region.setFrame", id: handleId,
            rect: { x: +q.x || 0, y: +q.y || 0, w: +q.w || 0, h: +q.h || 0 } });
        },
        eval(js)  { return request({ type: "overlay.region.eval", id: handleId, js: String(js ?? "") }); },
        remove()  { return request({ type: "overlay.region.remove", id: handleId }); }
      };
    }
  };
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
sd.httpserver = {
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
  };
