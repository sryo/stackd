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
sd.handlers = {
    register(kind, name, fn) { return __registerSlotHandler(kind, name, fn); }
  };
sd.bang = Object.assign(
    (name, detail) => request({ type: "bang", name, detail: detail || {} }),
    {
      declare(name) {
        const slug = __bangSlug(name);
        const dec = __ensureBangRouter(slug, name);
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
  );
