import Foundation
import JavaScriptCore

/// Tests for the `sd.util` namespace in `Runtime/api.js` — pure JS helpers
/// (debounce, throttle) that delegate to `sd.timer`. The harness's real
/// setTimeout is a no-op, so each test swaps in a manual timer queue
/// (`__utilFakeTimers`) that it flushes explicitly, then restores the
/// originals.
func registerUtilTests() {
    /// Wraps `body` (a JS function body that may call `flush()`) with a fake
    /// setTimeout / clearTimeout pair and returns its result as a String.
    func withFakeTimers(_ body: String) -> String? {
        JSHarness.evalString("""
        (function() {
          const realST = globalThis.setTimeout, realCT = globalThis.clearTimeout;
          const queue = new Map();
          let nextId = 1;
          globalThis.setTimeout = (fn) => { const id = nextId++; queue.set(id, fn); return id; };
          globalThis.clearTimeout = (id) => { queue.delete(id); };
          const pending = () => queue.size;
          const flush = () => {
            const fns = [...queue.values()];
            queue.clear();
            fns.forEach(fn => fn());
          };
          try {
            \(body)
          } finally {
            globalThis.setTimeout = realST;
            globalThis.clearTimeout = realCT;
          }
        })()
        """)
    }

    test("debounce: a burst of calls fires once, with the last call's args") {
        let out = withFakeTimers("""
            const seen = [];
            const f = sd.util.debounce((a) => { seen.push(a); }, 10);
            f(1); f(2); f(3);
            const before = seen.length + "/" + pending();
            flush();
            return before + "|" + seen.join(",");
        """)
        try expectEqual(out, "0/1|3")
    }

    test("debounce: cancel() prevents the pending call") {
        let out = withFakeTimers("""
            let calls = 0;
            const f = sd.util.debounce(() => { calls++; }, 10);
            f();
            f.cancel();
            flush();
            return calls + "/" + pending();
        """)
        try expectEqual(out, "0/0")
    }

    test("throttle: first call fires immediately (leading edge)") {
        let out = withFakeTimers("""
            let calls = 0;
            const f = sd.util.throttle(() => { calls++; }, 100000);
            f();
            return String(calls);
        """)
        try expectEqual(out, "1")
    }

    test("throttle: calls within the window collapse into one trailing call") {
        let out = withFakeTimers("""
            const seen = [];
            const f = sd.util.throttle((a) => { seen.push(a); }, 100000);
            f(1); f(2); f(3); f(4);
            const before = seen.join(",") + "/" + pending();
            flush();
            return before + "|" + seen.join(",");
        """)
        // The trailing call fires with the args of the call that armed it.
        try expectEqual(out, "1/1|1,2")
    }
}
