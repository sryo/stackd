import Foundation
import JavaScriptCore

/// Tests for `sd.bang.declare(name)` — the typed-handle bang registry.
/// Verifies emit routing through the postMessage spy, multi-listener
/// fan-out via simulated `window.onBang_<slug>` invocation, and that
/// legacy `sd.bang(name, detail)` + bare `window.onBang_*` assignments
/// keep working unchanged.
func registerBangRegistryTests() {
    test("declare: returns a handle with emit + on + name") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          const h = sd.bang.declare("test.brt.shape");
          return [h.name, typeof h.emit, typeof h.on].join('|');
        })()
        """)?.toString()
        try expectEqual(out, "test.brt.shape|function|function")
    }

    test("declare: emit dispatches a bang RPC carrying the declared name") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_emit = null;
          window.webkit.messageHandlers.sd.postMessage = (p) => {
            if (p.type === "bang") window.__brt_emit = p.name;
          };
          sd.bang.declare("test.brt.emit").emit({ x: 1 });
          return window.__brt_emit;
        })()
        """)?.toString()
        try expectEqual(out, "test.brt.emit")
    }

    test("declare: on() listener fires when the daemon dispatches via onBang_<slug>") {
        // The daemon calls `window.onBang_<slug>(detail)`. We simulate that
        // here by invoking the slot directly after registering an on() listener.
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_received = null;
          sd.bang.declare("test.brt.on").on(d => { window.__brt_received = d.v; });
          window.onBang_test_brt_on({ v: 42 });
          return String(window.__brt_received);
        })()
        """)?.toString()
        try expectEqual(out, "42")
    }

    test("declare: multiple on() listeners all fire on a single dispatch") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_fanout = 0;
          const h = sd.bang.declare("test.brt.fanout");
          h.on(() => { window.__brt_fanout += 1; });
          h.on(() => { window.__brt_fanout += 10; });
          h.on(() => { window.__brt_fanout += 100; });
          window.onBang_test_brt_fanout({});
          return String(window.__brt_fanout);
        })()
        """)?.toString()
        try expectEqual(out, "111")
    }

    test("declare: on() disposer removes the listener (no further calls)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_dispose = 0;
          const h = sd.bang.declare("test.brt.dispose");
          const stop = h.on(() => { window.__brt_dispose += 1; });
          window.onBang_test_brt_dispose({});
          stop();
          window.onBang_test_brt_dispose({});
          window.onBang_test_brt_dispose({});
          return String(window.__brt_dispose);
        })()
        """)?.toString()
        try expectEqual(out, "1")
    }

    test("declare: declaring the same name twice yields a shared listener set") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_share = 0;
          sd.bang.declare("test.brt.share").on(() => { window.__brt_share += 1; });
          sd.bang.declare("test.brt.share").on(() => { window.__brt_share += 10; });
          window.onBang_test_brt_share({});
          return String(window.__brt_share);
        })()
        """)?.toString()
        try expectEqual(out, "11")
    }

    test("declare: slugging matches Bridge.swift (lowercase + non-alphanumeric → _)") {
        // 'Foo.Bar-Baz' → 'foo_bar_baz'. The daemon will dispatch to
        // window.onBang_foo_bar_baz; on() must register against that slot.
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_slug = null;
          sd.bang.declare("Foo.Bar-Baz").on(d => { window.__brt_slug = d.tag; });
          window.onBang_foo_bar_baz({ tag: "ok" });
          return String(window.__brt_slug);
        })()
        """)?.toString()
        try expectEqual(out, "ok")
    }

    test("legacy: sd.bang(name, detail) still emits with the same RPC shape") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_legacy = null;
          window.webkit.messageHandlers.sd.postMessage = (p) => {
            if (p.type === "bang") window.__brt_legacy = p.name + "|" + (p.detail && p.detail.k);
          };
          sd.bang("test.brt.legacy", { k: "v" });
          return window.__brt_legacy;
        })()
        """)?.toString()
        try expectEqual(out, "test.brt.legacy|v")
    }

    test("legacy: pre-existing window.onBang_<slug> handler is preserved when declare attaches") {
        // Stacks that set window.onBang_X BEFORE anyone calls declare(X) must
        // still receive bangs. The router chains the prior handler.
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__brt_prior = 0;
          window.onBang_test_brt_prior = () => { window.__brt_prior += 1; };
          sd.bang.declare("test.brt.prior").on(() => { window.__brt_prior += 10; });
          window.onBang_test_brt_prior({});
          return String(window.__brt_prior);
        })()
        """)?.toString()
        try expectEqual(out, "11")
    }
}
