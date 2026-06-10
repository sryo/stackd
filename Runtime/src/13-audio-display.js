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
sd.audio = {
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
  };
sd.display = {
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
  };
