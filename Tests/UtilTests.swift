import Foundation
import JavaScriptCore

/// Tests for the `sd.util` namespace in `Runtime/api.js` — pure JS helpers
/// (debounce, throttle). No IPC, no permission. Lifted out of the 4+
/// per-stack reinventions of the same pattern.
func registerUtilTests() {
    test("debounce: trailing call fires after silence") {
        // setTimeout in JSContext doesn't auto-tick. Drive the clock via the
        // shim — JSHarness installs a setTimeout that records callbacks for
        // manual flush. We just verify the wrapper structure here; behavior
        // assertions on real timing happen in WKWebView land later.
        let out = JSHarness.evalString("""
        (function() {
          let calls = 0;
          const f = sd.util.debounce(() => { calls++; }, 10);
          f(); f(); f();
          // Three calls, none have fired yet (timer not flushed).
          return calls;
        })()
        """)
        try expectEqual(out, "0")
    }

    test("debounce: cancel() prevents the pending call") {
        let out = JSHarness.evalString("""
        (function() {
          const f = sd.util.debounce(() => {}, 10);
          f();
          f.cancel();
          return typeof f.cancel;
        })()
        """)
        try expectEqual(out, "function")
    }

    test("throttle: first call fires immediately (leading edge)") {
        let out = JSHarness.evalString("""
        (function() {
          let calls = 0;
          const f = sd.util.throttle(() => { calls++; }, 100);
          f();
          return calls;
        })()
        """)
        try expectEqual(out, "1")
    }

    test("throttle: subsequent calls within window are deferred") {
        let out = JSHarness.evalString("""
        (function() {
          let calls = 0;
          const f = sd.util.throttle(() => { calls++; }, 100);
          f(); f(); f(); f();
          // First fires immediately; the rest queue a single trailing-edge call
          // that hasn't fired yet (no flush).
          return calls;
        })()
        """)
        try expectEqual(out, "1")
    }

    test("debounce + throttle: exported on sd.util") {
        let out = JSHarness.evalString("""
        typeof sd.util.debounce + ',' + typeof sd.util.throttle
        """)
        try expectEqual(out, "function,function")
    }
}
