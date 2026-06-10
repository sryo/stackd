sd.events = {
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
  };
  // Cursor — warp / read. Top-left global coords by default (same convention
  // as sd.mouse). Pass `display` (CGDirectDisplayID from sd.display.all) to
  // interpret coords as display-local.
  //   await sd.cursor.setPosition({ x: 100, y: 200 });
  //   await sd.cursor.setPosition({ x: 0, y: 0, display: displays[1].displayID });
  //   const p = await sd.cursor.position();   // { x, y } — top-left global
  // Consumers: EdgeHopper (wrap cursor to opposite edge on punch-through);
  // CloudPad (in-process replacement for the JXA CGWarpMouseCursorPosition
  // shim under continuous pointer-mode moves).
sd.cursor = {
    setPosition(p) {
      const o = p || {};
      return request({ type: "cursor.setPosition", x: o.x, y: o.y, display: o.display });
    },
    position() { return request({ type: "cursor.position" }); }
  };
