import Foundation
import AppKit
import WebKit

/// A loaded page with a Bridge attached. The page records every answer the
/// bridge sends through `window.__sd_response(requestId, value)` and every
/// channel push through `window.__sd_push(name, payload)`, as JSON strings.
struct BridgedPage {
    let webView: WKWebView
    let bridge: Bridge

    init() throws {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        bridge = Bridge(webView: webView)
        final class Nav: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }
        let nav = Nav()
        webView.navigationDelegate = nav
        webView.loadHTMLString("""
        <body><script>
        window.__answers = {};
        window.__pushes = {};
        window.__sd_response = function (id, value) { window.__answers[id] = JSON.stringify(value); };
        window.__sd_push = function (name, value) { window.__pushes[name] = JSON.stringify(value); };
        </script></body>
        """, baseURL: nil)
        BridgedPage.spin(for: 10) { nav.done }
        webView.navigationDelegate = nil
        try expect(nav.done, "webview never finished loading")
    }

    /// Starts the bridge as a stack holding exactly `permissions`.
    func start(permissions: [String]) throws {
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        let manifest = try JSONDecoder().decode(StackManifest.self, from: Data("""
        {"id":"stackd-tests-bridge","name":"t","size":{"w":1,"h":1},"permissions":[\(list)]}
        """.utf8))
        bridge.start(manifest: manifest)
    }

    static func spin(for seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func eval(_ expr: String) -> Any? {
        var out: Any?
        var done = false
        webView.evaluateJavaScript(expr) { v, _ in out = v; done = true }
        BridgedPage.spin(for: 10) { done }
        return out
    }

    /// Polls the string expression `expr` until it is non-empty or `seconds`
    /// pass; nil when it stayed empty.
    func waitFor(_ expr: String, seconds: TimeInterval = 3) -> String? {
        var got = ""
        BridgedPage.spin(for: seconds) {
            got = eval("\(expr) || ''") as? String ?? ""
            return !got.isEmpty
        }
        return got.isEmpty ? nil : got
    }

    /// Posts `message` through the page's real `sd` message handler and
    /// returns the JSON of the value Bridge answered with, or nil when no
    /// answer arrived.
    func answer(requestId: Int, _ message: String) -> String? {
        _ = eval("window.webkit.messageHandlers.sd.postMessage(\(message)); 0")
        return waitFor("window.__answers[\(requestId)]")
    }

    /// JSON of the last payload pushed on `channel`, waiting for the first.
    func pushed(_ channel: String) -> String? {
        waitFor("window.__pushes[\(Bridge.jsString(channel))]")
    }
}

// End-to-end tests for Bridge's RPC entry point: the page posts to the real
// `sd` message handler, and the answer comes back through
// `window.__sd_response` — the only channel a runtime `request()` Promise
// resolves on.
func registerBridgeDispatchTests() {
    test("dispatch: a known primitive answers its request") {
        let page = try BridgedPage()
        try expectEqual(page.answer(requestId: 11, #"{type: "bang.handle", name: "x", requestId: 11}"#), "true")
    }

    test("dispatch: a primitive the stack lacks permission for answers its deny value") {
        let page = try BridgedPage()
        try expectEqual(page.answer(requestId: 12, #"{type: "mouse.warp", x: 1, y: 1, requestId: 12}"#), "false")
    }

    test("dispatch: an unknown type answers null instead of leaving the request pending") {
        let page = try BridgedPage()
        try expectEqual(page.answer(requestId: 13, #"{type: "no.such.primitive", requestId: 13}"#), "null")
    }

    test("dispatch: a message without a type answers null") {
        let page = try BridgedPage()
        try expectEqual(page.answer(requestId: 14, #"{requestId: 14}"#), "null")
    }
}
