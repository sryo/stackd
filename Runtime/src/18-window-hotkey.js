sd.window = {
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
  };
sd.hotkey = {
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
  };
