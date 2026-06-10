sd.util = util;
sd.timer = timer;
  // Per-instance screen info, injected before this script runs (see Bridge.swift).
  // Read .current synchronously — items like spacenum + brightness need to
  // know which screen they're rendered on without an async round-trip.
sd.screen = { current: window.__sd_screen || null };
sd.battery = channel("battery");
sd.mouse = Object.assign(channel("mouse"), {
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
  });
sd.appearance = channel("appearance");
sd.app = {
    frontmost: channel("frontApp"),
    // Fires when the frontmost app changes (F15 split of the legacy
    // sd.windows.focused union). Payload matches sd.app.frontmost — same
    // { app, pid, bundleId, ... } dict shape. Permission: "app".
    activated: channel("appActivated")
  };
