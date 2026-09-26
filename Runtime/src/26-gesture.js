  // Gesture physics for stacks that track fingers or scrolls continuously.
  // Pure JS, no permission; units are whatever the caller feeds in (px,
  // normalized trackpad units, ...), time in milliseconds, velocities per
  // second.
  //
  //   const vt = sd.gesture.velocityTracker();      // 100 ms window
  //   vt.add(e.timestamp * 1000, x);                // per touch frame
  //   const v = vt.velocity(performance.now()).x;   // on release
  //   const rest = sd.gesture.project(x, v);        // where a flick lands
  //   const target = sd.gesture.snap(x, v, [0, 400, 800]);
  //   const s = sd.gesture.spring({ from: x, to: target, velocity: v,
  //                                 onUpdate: (x) => place(x) });
  //   // finger lands again mid-flight: take over from where it is
  //   const { value, velocity } = s.stop();
  //
  // spring() ticks on sd.displayLink, so a stack using it needs the
  // displayLink permission (inferred from `sd.gesture.spring` in source).
sd.gesture = {
    // Least-squares velocity over the samples inside a trailing window
    // (clamped to 80..150 ms). add(t, x, y?) with t in ms; velocity(now?)
    // → { x, y } per second, zero when fewer than two samples or when
    // `now` is more than one window past the last sample (the finger
    // stopped before lifting).
    velocityTracker(opts) {
      const windowMs = Math.min(150, Math.max(80, (opts && opts.window) || 100));
      let samples = [];
      return {
        add(t, x, y) {
          samples.push({ t, x, y: y || 0 });
          const cutoff = t - windowMs;
          while (samples.length > 2 && samples[0].t < cutoff) samples.shift();
        },
        velocity(now) {
          const n = samples.length;
          if (n < 2) return { x: 0, y: 0 };
          const last = samples[n - 1];
          if (now != null && now - last.t > windowMs) return { x: 0, y: 0 };
          const live = samples.filter((s) => s.t >= last.t - windowMs);
          if (live.length < 2) return { x: 0, y: 0 };
          let mt = 0, mx = 0, my = 0;
          for (const s of live) { mt += s.t; mx += s.x; my += s.y; }
          mt /= live.length; mx /= live.length; my /= live.length;
          let stt = 0, stx = 0, sty = 0;
          for (const s of live) {
            const dt = s.t - mt;
            stt += dt * dt; stx += dt * (s.x - mx); sty += dt * (s.y - my);
          }
          if (stt === 0) return { x: 0, y: 0 };
          return { x: (stx / stt) * 1000, y: (sty / stt) * 1000 };
        },
        reset() { samples = []; }
      };
    },

    // Clamp with resistance: inside [min, max] the value passes through;
    // past an edge the overshoot d maps to (1 - 1/(d*c/dim + 1)) * dim, so
    // it approaches but never exceeds `dimension` beyond the edge.
    rubberBand(value, min, max, dimension, coefficient) {
      const c = coefficient == null ? 0.55 : coefficient;
      const band = (d) => (1 - 1 / ((d * c) / dimension + 1)) * dimension;
      if (value < min) return min - band(min - value);
      if (value > max) return max + band(value - max);
      return value;
    },

    // Rest position of a release at `velocity` (per second) under
    // exponential deceleration `decay` per millisecond (0.997 ≈ UIScrollView
    // normal).
    project(position, velocity, decay) {
      const d = decay == null ? 0.997 : decay;
      return position + (velocity / 1000) * d / (1 - d);
    },

    // The target nearest to the projected rest position — the commit
    // decision for a flick that should land on one of several stops.
    snap(position, velocity, targets, decay) {
      if (!targets || targets.length === 0) return position;
      const p = sd.gesture.project(position, velocity, decay);
      let best = targets[0];
      for (const t of targets) if (Math.abs(t - p) < Math.abs(best - p)) best = t;
      return best;
    },

    // One step of a critically damped spring toward `target`, exact for any
    // dt (seconds): x(t) = target + (c1 + c2·t)·e^(−ωt) with c1 = x0 − target,
    // c2 = v0 + ω·c1 and ω = 2π / response.
    springStep(value, velocity, target, response, dt) {
      const w = (2 * Math.PI) / response;
      const c1 = value - target;
      const c2 = velocity + w * c1;
      const e = Math.exp(-w * dt);
      return {
        value: target + (c1 + c2 * dt) * e,
        velocity: (c2 - w * (c1 + c2 * dt)) * e
      };
    },

    // Critically damped spring from `from` to `to`, advanced on every
    // sd.displayLink tick (or `opts.ticker`, anything with
    // subscribe(fn) → unsubscribe). Catchable: stop() halts it where it is
    // and returns { value, velocity } for the gesture to take over;
    // retarget(to) keeps the current velocity. Settles when within
    // restDelta of the target and slower than restSpeed (per second), then
    // snaps to the target and calls onComplete.
    //   opts: { from, to, velocity = 0, response = 0.35 s,
    //           restDelta = 0.01, restSpeed = 0.1,
    //           onUpdate(value, velocity), onComplete(value), ticker }
    spring(opts) {
      const o = opts || {};
      const response = o.response || 0.35;
      const restDelta = o.restDelta == null ? 0.01 : o.restDelta;
      const restSpeed = o.restSpeed == null ? 0.1 : o.restSpeed;
      const ticker = o.ticker || sd.displayLink;
      let value = o.from, velocity = o.velocity || 0, target = o.to;
      let lastTs = null, unsub = null, running = true;

      const finish = () => {
        running = false;
        if (unsub) { const u = unsub; unsub = null; u(); }
      };
      const tick = (frame) => {
        if (!running) return;
        const ts = frame && typeof frame.timestamp === "number" ? frame.timestamp : null;
        if (ts == null) return;
        if (lastTs == null || ts <= lastTs) { lastTs = ts; return; }
        const dt = Math.min(ts - lastTs, 0.1);
        lastTs = ts;
        const next = sd.gesture.springStep(value, velocity, target, response, dt);
        value = next.value; velocity = next.velocity;
        if (Math.abs(value - target) < restDelta && Math.abs(velocity) < restSpeed) {
          value = target; velocity = 0;
          finish();
          if (o.onUpdate) o.onUpdate(value, velocity);
          if (o.onComplete) o.onComplete(value);
          return;
        }
        if (o.onUpdate) o.onUpdate(value, velocity);
      };
      const handle = {
        get value() { return value; },
        get velocity() { return velocity; },
        get running() { return running; },
        retarget(to) { target = to; },
        stop() { finish(); return { value, velocity }; }
      };
      unsub = ticker.subscribe(tick);
      if (!running && unsub) { const u = unsub; unsub = null; u(); }
      return handle;
    }
  };
