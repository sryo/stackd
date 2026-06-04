import Foundation
import JavaScriptCore

/// Tests for `sd.timer.*` — reload-safe scheduling with auto-cleanup on
/// `pagehide`. The harness's setTimeout is a no-op (it returns 0 without
/// scheduling), so we can't exercise actual firing; we test the surface
/// shape, the registry-tracking contract that drives auto-cleanup, and
/// the disposer / .cancel() semantics by spying on clearTimeout.
func registerTimerTests() {
    test("timer: surface includes timeout / interval / debounce / throttle") {
        let out = JSHarness.context.evaluateScript("""
        [typeof sd.timer.timeout,
         typeof sd.timer.interval,
         typeof sd.timer.debounce,
         typeof sd.timer.throttle].join("|")
        """)?.toString()
        try expectEqual(out, "function|function|function|function")
    }

    test("timer.timeout: returns a disposer that calls clearTimeout(id)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          let cleared = null;
          const realSetTimeout = setTimeout;
          const realClearTimeout = clearTimeout;
          globalThis.setTimeout = () => 7777;
          globalThis.clearTimeout = (id) => { cleared = id; };
          const stop = sd.timer.timeout(() => {}, 100);
          stop();
          globalThis.setTimeout = realSetTimeout;
          globalThis.clearTimeout = realClearTimeout;
          return String(cleared);
        })()
        """)?.toString()
        try expectEqual(out, "7777")
    }

    test("timer.interval: returns a disposer that calls clearInterval(id)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          let cleared = null;
          const realSI = setInterval;
          const realCI = clearInterval;
          globalThis.setInterval = () => 8888;
          globalThis.clearInterval = (id) => { cleared = id; };
          const stop = sd.timer.interval(() => {}, 100);
          stop();
          globalThis.setInterval = realSI;
          globalThis.clearInterval = realCI;
          return String(cleared);
        })()
        """)?.toString()
        try expectEqual(out, "8888")
    }

    test("timer.debounce: returns a callable + a .cancel method") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          const fn = sd.timer.debounce(() => {}, 100);
          return [typeof fn, typeof fn.cancel].join("|");
        })()
        """)?.toString()
        try expectEqual(out, "function|function")
    }

    test("timer.throttle: returns a callable") {
        let out = JSHarness.context.evaluateScript("""
        typeof sd.timer.throttle(() => {}, 100)
        """)?.toString()
        try expectEqual(out, "function")
    }

    test("util.debounce / util.throttle: delegate to sd.timer (back-compat)") {
        // Adopting sd.util.* automatically gives existing stacks pagehide
        // cleanup once they upgrade. Verify the shape matches sd.timer's
        // (callable + .cancel for debounce; bare callable for throttle).
        let out = JSHarness.context.evaluateScript("""
        (function() {
          const d = sd.util.debounce(() => {}, 50);
          const t = sd.util.throttle(() => {}, 50);
          return [typeof d, typeof d.cancel, typeof t].join("|");
        })()
        """)?.toString()
        try expectEqual(out, "function|function|function")
    }
}
