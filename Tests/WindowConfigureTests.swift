import Foundation
import JavaScriptCore

/// Tests for `sd.window.configure(spec)` — the JS aggregator over the
/// daemon's setAlpha / setClickThrough / setFrame RPC handlers.
///
/// The postMessage bridge stub is replaced with a spy that captures every
/// RPC payload; tests assert on which RPC types were dispatched. Body
/// parsing on the daemon side is covered by WindowLifecycleTests
/// (StackWindow.parseSet*).
func registerWindowConfigureTests() {
    func spyAndConfigure(_ spec: String) -> [String] {
        let probe = """
        (function() {
          window.__cfg_captured = [];
          window.webkit.messageHandlers.sd.postMessage = (p) => window.__cfg_captured.push(p);
          sd.window.configure(\(spec));
          return JSON.stringify(window.__cfg_captured.map(p => p.type));
        })()
        """
        let raw = JSHarness.context.evaluateScript(probe)?.toString() ?? "[]"
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }

    test("configure: empty spec issues no RPCs") {
        let types = spyAndConfigure("{}")
        try expectEqual(types.count, 0)
    }

    test("configure: clickThrough-only spec issues exactly window.setClickThrough") {
        let types = spyAndConfigure("{ clickThrough: true }")
        try expectEqual(types, ["window.setClickThrough"])
    }

    test("configure: frame payload carries x/y/w/h through to window.setFrame") {
        let out = JSHarness.evalString("""
        (function() {
          let p = null;
          window.webkit.messageHandlers.sd.postMessage = (m) => { if (m.type === 'window.setFrame') p = m; };
          sd.window.configure({ frame: { x: 10, y: 20, w: 300, h: 200 } });
          return p ? [p.x, p.y, p.w, p.h].join(',') : 'null';
        })()
        """)
        try expectEqual(out, "10,20,300,200")
    }

    test("configure: frame-only spec issues exactly window.setFrame") {
        let types = spyAndConfigure("{ frame: { x: 10, y: 20, w: 100, h: 50 } }")
        try expectEqual(types, ["window.setFrame"])
    }

    test("configure: full spec issues all three RPCs in stable order") {
        let types = spyAndConfigure("{ alpha: 0.5, clickThrough: false, frame: { x: 0, y: 0 } }")
        try expectEqual(types, ["window.setAlpha", "window.setClickThrough", "window.setFrame"])
    }

    test("configure: alpha-only spec issues exactly window.setAlpha (alpha:0 isn't dropped as falsy)") {
        let types = spyAndConfigure("{ alpha: 0 }")
        try expectEqual(types, ["window.setAlpha"])
    }

    test("configure: clickThrough:false is dispatched (uses !== undefined check)") {
        let types = spyAndConfigure("{ clickThrough: false }")
        try expectEqual(types, ["window.setClickThrough"])
    }

    test("configure: alpha payload carries the value through to the RPC") {
        _ = JSHarness.context.evaluateScript("""
            window.__cfg_alpha_payload = null;
            window.webkit.messageHandlers.sd.postMessage = (p) => {
              if (p.type === 'window.setAlpha') window.__cfg_alpha_payload = p.value;
            };
            sd.window.configure({ alpha: 0.42 });
        """)
        let out = JSHarness.context.evaluateScript("String(window.__cfg_alpha_payload)")?.toString()
        try expectEqual(out, "0.42")
    }

    test("configure: unknown spec fields are silently ignored (no extra RPC)") {
        let types = spyAndConfigure("{ alpha: 1, fontWeight: 'bold', nope: 42 }")
        try expectEqual(types, ["window.setAlpha"])
    }

    test("configure: null spec is treated as empty (no throw)") {
        let types = spyAndConfigure("null")
        try expectEqual(types.count, 0)
    }
}
