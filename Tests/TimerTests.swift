import Foundation
import JavaScriptCore

/// Tests for `sd.timer.*` — reload-safe scheduling with auto-cleanup on
/// `pagehide`. The harness's setTimeout is a no-op, so each test swaps in
/// a recording fake (setTimeout returns increasing ids and stores the
/// callback; clearTimeout records the cleared id) and runs the stored
/// callbacks by hand. The fakes are restored in `finally` so a failing
/// test can't leak them into later JS tests.
func registerTimerTests() {
    let fakeTimers = """
    function __withFakeTimers(body) {
      const real = { st: setTimeout, ct: clearTimeout, si: setInterval, ci: clearInterval };
      const t = { next: 100, pending: new Map(), cleared: [] };
      globalThis.setTimeout  = (fn) => { const id = t.next++; t.pending.set(id, fn); return id; };
      globalThis.clearTimeout = (id) => { t.cleared.push(id); t.pending.delete(id); };
      globalThis.setInterval  = (fn) => { const id = t.next++; t.pending.set(id, fn); return id; };
      globalThis.clearInterval = (id) => { t.cleared.push(id); t.pending.delete(id); };
      t.runAll = () => { const fns = [...t.pending.values()]; t.pending.clear(); fns.forEach((f) => f()); };
      try { return body(t); }
      finally {
        globalThis.setTimeout = real.st; globalThis.clearTimeout = real.ct;
        globalThis.setInterval = real.si; globalThis.clearInterval = real.ci;
      }
    }
    """
    _ = JSHarness.context.evaluateScript(fakeTimers)

    test("timer.timeout: returns a disposer that calls clearTimeout(id)") {
        let out = JSHarness.evalString("""
        __withFakeTimers((t) => {
          const stop = sd.timer.timeout(() => {}, 100);
          stop();
          return t.cleared.join(",");
        })
        """)
        try expectEqual(out, "100")
    }

    test("timer.interval: returns a disposer that calls clearInterval(id)") {
        let out = JSHarness.evalString("""
        __withFakeTimers((t) => {
          const stop = sd.timer.interval(() => {}, 100);
          stop();
          return t.cleared.join(",");
        })
        """)
        try expectEqual(out, "100")
    }

    test("timer.debounce: a burst fires once, trailing, with the last call's args") {
        let out = JSHarness.evalString("""
        __withFakeTimers((t) => {
          const calls = [];
          const fn = sd.timer.debounce((v) => calls.push(v), 100);
          fn("a"); fn("b"); fn("c");
          const clearedDuringBurst = t.cleared.length;
          const beforeRun = calls.length;
          t.runAll();
          return [beforeRun, clearedDuringBurst, t.pending.size, calls.join("")].join("|");
        })
        """)
        // Two re-arms cancel the two earlier timers; only "c" fires.
        try expectEqual(out, "0|2|0|c")
    }

    test("timer.debounce: .cancel() drops the pending call") {
        let out = JSHarness.evalString("""
        __withFakeTimers((t) => {
          let fired = 0;
          const fn = sd.timer.debounce(() => fired++, 100);
          fn();
          fn.cancel();
          t.runAll();
          return fired + "|" + t.cleared.length;
        })
        """)
        try expectEqual(out, "0|1")
    }

    test("timer.throttle: leading call fires at once, calls inside the window collapse to one trailing call") {
        let out = JSHarness.evalString("""
        __withFakeTimers((t) => {
          const calls = [];
          const fn = sd.timer.throttle((v) => calls.push(v), 60000);
          fn("a"); fn("b"); fn("c");
          const leading = calls.join("");
          const scheduled = t.pending.size;
          t.runAll();
          return [leading, scheduled, calls.join("")].join("|");
        })
        """)
        // The trailing call keeps the args of the call that armed it.
        try expectEqual(out, "a|1|ab")
    }

    test("util.debounce / util.throttle: delegate to sd.timer (back-compat)") {
        // sd.util.* call sites get the tracked sd.timer behavior, including
        // debounce's .cancel().
        let out = JSHarness.evalString("""
        __withFakeTimers((t) => {
          let d = 0, th = 0;
          const deb = sd.util.debounce(() => d++, 50);
          deb(); deb();
          t.runAll();
          const thr = sd.util.throttle(() => th++, 60000);
          thr();
          return [d, th, typeof deb.cancel].join("|");
        })
        """)
        try expectEqual(out, "1|1|function")
    }
}
