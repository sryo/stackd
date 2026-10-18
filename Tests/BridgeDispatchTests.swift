import Foundation
import AppKit
import WebKit

// End-to-end tests for Bridge's RPC entry point: the page posts to the real
// `sd` message handler Bridge registers on its WebView, and the answer comes
// back through `window.__sd_response(requestId, value)` — the only channel a
// `request()` Promise in the runtime resolves on.

private func spinDispatchRunLoop(for seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

private func evalDispatchJS(_ wv: WKWebView, _ expr: String) -> Any? {
    var out: Any?
    var done = false
    wv.evaluateJavaScript(expr) { v, _ in out = v; done = true }
    spinDispatchRunLoop(for: 10) { done }
    return out
}

/// A page whose `__sd_response` records every answer, with a Bridge attached.
private func bridgedPage() throws -> (WKWebView, Bridge) {
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    let bridge = Bridge(webView: wv)
    final class Nav: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }
    let nav = Nav()
    wv.navigationDelegate = nav
    wv.loadHTMLString("""
    <body><script>
    window.__answers = {};
    window.__sd_response = function (id, value) { window.__answers[id] = JSON.stringify(value); };
    </script></body>
    """, baseURL: nil)
    spinDispatchRunLoop(for: 10) { nav.done }
    wv.navigationDelegate = nil
    try expect(nav.done, "webview never finished loading")
    return (wv, bridge)
}

/// Posts `message` through the page's `sd` handler and returns the JSON of
/// the value Bridge answered with, or nil when no answer arrived.
private func answer(_ wv: WKWebView, requestId: Int, _ message: String) -> String? {
    _ = evalDispatchJS(wv, "window.webkit.messageHandlers.sd.postMessage(\(message)); 0")
    var got: String?
    spinDispatchRunLoop(for: 3) {
        got = evalDispatchJS(wv, "window.__answers[\(requestId)] || ''") as? String
        return !(got ?? "").isEmpty
    }
    return (got ?? "").isEmpty ? nil : got
}

func registerBridgeDispatchTests() {
    test("dispatch: a known primitive answers its request") {
        let (wv, bridge) = try bridgedPage()
        defer { withExtendedLifetime(bridge) {} }
        try expectEqual(answer(wv, requestId: 11, #"{type: "bang.handle", name: "x", requestId: 11}"#), "true")
    }

    test("dispatch: a primitive the stack lacks permission for answers its deny value") {
        let (wv, bridge) = try bridgedPage()
        defer { withExtendedLifetime(bridge) {} }
        try expectEqual(answer(wv, requestId: 12, #"{type: "mouse.warp", x: 1, y: 1, requestId: 12}"#), "false")
    }

    test("dispatch: an unknown type answers null instead of leaving the request pending") {
        let (wv, bridge) = try bridgedPage()
        defer { withExtendedLifetime(bridge) {} }
        try expectEqual(answer(wv, requestId: 13, #"{type: "no.such.primitive", requestId: 13}"#), "null")
    }

    test("dispatch: a message without a type answers null") {
        let (wv, bridge) = try bridgedPage()
        defer { withExtendedLifetime(bridge) {} }
        try expectEqual(answer(wv, requestId: 14, #"{requestId: 14}"#), "null")
    }
}
