  // Per-screen Spaces info via SkyLight private SPI:
  //   { [screenUUID]: { spaces: [id, ...], active: id|null, isFullscreen: bool } }
  // Fires on NSWorkspaceActiveSpaceDidChangeNotification.
  // Banner notifications via macOS Notification Center. Fire-and-forget.
  // Attributed to "Script Editor" (osascript) until stackd ships as a
  // bundled .app — click handling deferred until then.
  //   await sd.notify.show({ title: "AppTimeout", body: "Slack closes in 1 min" });
sd.notify = {
    show(spec) {
      return request({
        type: "notify.show",
        title: (spec && spec.title) || "",
        body: (spec && spec.body) || "",
        subtitle: spec && spec.subtitle,
        sound: spec && spec.sound
      });
    }
  };
  // Play short sounds via NSSound. Fire-and-forget; no completion callback.
  //   sd.sound.system("Glass")           // /System/Library/Sounds/Glass.aiff
  //   sd.sound.file("~/Music/ding.mp3")  // arbitrary file (~ expanded)
  //   sd.sound.beep()                    // NSBeep
sd.sound = {
    system(name) { return request({ type: "sound.system", name }); },
    file(path)   { return request({ type: "sound.file",   path }); },
    beep()       { return request({ type: "sound.beep" }); }
  };
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
sd.caffeinate = Object.assign(channel("caffeinate"), {
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
  });
  // Vsync-locked frame tick. Refresh rate matches the display (60 Hz on
  // standard, 120 Hz on ProMotion). Cheaper + smoother than rAF inside a
  // heavy WebView, and aligned to the compositor's flip cadence —
  // sd.overlay uses the same observer to reposition the overlay panel.
  //   sd.displayLink.subscribe(({ timestamp, frame, refreshRate }) => { ... })
sd.displayLink = channel("displayLink");
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
sd.host = {
    info()   { return request({ type: "host.info" }); },
    diskIO() { return request({ type: "host.diskIO" }); },
    load:    channel("hostLoad")
  };
  // Mac internal sensors via IOHIDEventSystem (Apple silicon: per-die temps,
  // per-rail voltage/current, fan RPM). Polled at 2s. Intel SMC sensors deferred.
  //   sd.sensors → { temperatures: [{name,value,unit}, ...], voltages: [...],
  //                  currents: [...], fans: [{name, rpm}, ...] }
  // Tunable cadence — pass `{ interval }` (seconds) to slow this stack's
  // fanout:
  //   sd.sensors.subscribe(s => updateTempUI(s), { interval: 5 });
sd.sensors = channel("sensors");
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
sd.touchdevice = channel("touchdevice");
