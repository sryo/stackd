sd.windows = {
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
    //
    // Animated form (hs.window:setFrame(rect, duration) parity, id form only):
    //   sd.windows.setFrame(id, frame, { duration: 0.18, easing: "easeOutCubic" })
    // Easings: "easeOutCubic" (default when duration > 0), "linear", "spring"
    // (spring derives its own settle time; duration is ignored). The daemon
    // ticks every animating window on ONE display-link clock, so a
    // multi-window pass moves in lockstep — no per-window rAF stagger. The
    // promise resolves at settle: true = reached target, false = superseded
    // by a later setFrame / cancelAnimation on the same window.
    setFrame(arg1, arg2, arg3) {
      if (typeof arg1 === "number") {
        const f = arg2 || {};
        const o = arg3 || {};
        return request({ type: "windows.byId.setFrame", id: arg1, x: f.x, y: f.y, w: f.w, h: f.h,
                         duration: o.duration, easing: o.easing });
      }
      const f = arg1 || {};
      return request({ type: "windows.setFrame", x: f.x, y: f.y, w: f.w, h: f.h });
    },
    isAnimating(id)     { return request({ type: "windows.byId.isAnimating", id }); },
    // Stops the animation where it is (the in-flight setFrame promise
    // resolves false). The window stays at the last-ticked frame.
    cancelAnimation(id) { return request({ type: "windows.byId.cancelAnimation", id }); },
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
    // Multi-window frame batch. setFrame calls with an explicit id inside
    // the closure are queued (last-write-wins per window) and applied in one
    // daemon-side burst on closure return — every frame rides the same AX
    // channel, so the old SLS/AX split race can't misplace windows. For an
    // ANIMATED multi-window pass, skip batch and issue parallel
    // setFrame(id, frame, {duration}) calls instead — the motion engine
    // already ticks them on one clock. Calls without an id (which target
    // the AX focused window) bypass batching. Throws-through; queued ops
    // are dropped via commit-empty-then-rethrow.
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
  };
