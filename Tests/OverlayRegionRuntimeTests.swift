import Foundation
import JavaScriptCore

// Runtime side of sd.overlay.region (Runtime/src/19-ipc.js + 00-core.js):
// the create payload carries `interactive` / `level`, and a page's
// window.stack.post, fired back as __sd_overlay_message, reaches the
// handle's onMessage until the handle is removed.
//
// Promises settle between evaluateScript calls (JSContext drains its
// microtasks when a script returns), so each step is its own script.

func registerOverlayRegionRuntimeTests() {
    test("sd.overlay.region sends interactive and level in the create payload") {
        let ctx = JSHarness.context
        ctx.evaluateScript("""
        globalThis.__orr = { real: window.webkit.messageHandlers.sd.postMessage, sent: null };
        window.webkit.messageHandlers.sd.postMessage = (p) => {
          if (p.type === "overlay.region.create") __orr.sent = p;
        };
        sd.overlay.region({ rect: { x: 0, y: 0, w: 10, h: 10 }, interactive: true, level: "utility" });
        window.webkit.messageHandlers.sd.postMessage = __orr.real;
        """)
        try expectEqual(ctx.evaluateScript("__orr.sent.interactive")?.toBool(), true)
        try expectEqual(ctx.evaluateScript("__orr.sent.level")?.toString(), "utility")
        ctx.evaluateScript("""
        window.webkit.messageHandlers.sd.postMessage = (p) => {
          if (p.type === "overlay.region.create") __orr.sent = p;
        };
        sd.overlay.region({ rect: { x: 0, y: 0, w: 10, h: 10 } });
        window.webkit.messageHandlers.sd.postMessage = __orr.real;
        """)
        try expectEqual(ctx.evaluateScript("__orr.sent.interactive")?.toBool(), false)
    }

    test("sd.overlay.region: onMessage receives the page's posts until remove()") {
        let ctx = JSHarness.context
        ctx.evaluateScript("""
        globalThis.__orm = { real: window.webkit.messageHandlers.sd.postMessage, got: [], handle: null };
        window.webkit.messageHandlers.sd.postMessage = (p) => {
          if (p.type === "overlay.region.create") setTimeoutless(() => window.__sd_response(p.requestId, 9001));
        };
        function setTimeoutless(fn) { Promise.resolve().then(fn); }
        sd.overlay.region({ rect: { x: 0, y: 0, w: 10, h: 10 } }).then((h) => { __orm.handle = h; });
        window.webkit.messageHandlers.sd.postMessage = __orm.real;
        """)
        try expectEqual(ctx.evaluateScript("__orm.handle && __orm.handle.id")?.toInt32(), 9001)
        ctx.evaluateScript("""
        __orm.handle.onMessage((d) => __orm.got.push(d.kind));
        window.__sd_overlay_message(9001, { kind: "down" });
        window.__sd_overlay_message(4242, { kind: "other-region" });
        __orm.handle.remove();
        window.__sd_overlay_message(9001, { kind: "after-remove" });
        """)
        try expectEqual(ctx.evaluateScript("__orm.got.join(',')")?.toString(), "down")
    }
}
