import Foundation
import AppKit
import WebKit

// Tests for `Sources/WebViewEval.swift`.
//
// `sdEvaluate` must behave like `evaluateJavaScript` for any script size:
// global scope, completion value, and in-order delivery relative to the
// small-script path. Scripts past `WebViewEval.inlineLimit` travel as a
// callAsyncJavaScript argument instead of script source, because WebKit
// never frees the out-of-line IPC buffer behind a large evaluateJavaScript
// source in the host process.
//
// NOT covered here: the footprint itself. "Owned physical footprint
// (unmapped)" is only readable via `footprint`/`vmmap` on the process —
// verified by hand against the running daemon.

private func spinEvalRunLoop(for seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

private func loadedWebView() throws -> WKWebView {
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    final class Nav: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }
    let nav = Nav()
    wv.navigationDelegate = nav
    wv.loadHTMLString("<body></body>", baseURL: nil)
    spinEvalRunLoop(for: 10) { nav.done }
    wv.navigationDelegate = nil
    try expect(nav.done, "webview never finished loading")
    return wv
}

private func read(_ wv: WKWebView, _ expr: String) -> Any? {
    var out: Any?
    var done = false
    wv.evaluateJavaScript(expr) { v, _ in out = v; done = true }
    spinEvalRunLoop(for: 10) { done }
    return out
}

func registerWebViewEvalTests() {
    let big = String(repeating: "A", count: WebViewEval.inlineLimit * 4)

    test("sdEvaluate: a large script runs in page global scope") {
        let wv = try loadedWebView()
        wv.sdEvaluate("var __big = '\(big)'; window.__bigLen = __big.length;")
        try expectEqual((read(wv, "window.__bigLen") as? NSNumber)?.intValue, big.count)
        // `var` at top level must land on window, like a classic script.
        try expectEqual((read(wv, "typeof window.__big") as? String), "string")
    }

    test("sdEvaluate: a large script's completion gets the script's value") {
        let wv = try loadedWebView()
        var got: Any?
        var done = false
        wv.sdEvaluate("'\(big)'.length + 1") { v, _ in got = v; done = true }
        spinEvalRunLoop(for: 10) { done }
        try expectEqual((got as? NSNumber)?.intValue, big.count + 1)
    }

    test("sdEvaluate: large and small scripts run in call order") {
        let wv = try loadedWebView()
        wv.sdEvaluate("window.__order = [];")
        for i in 0..<6 {
            let pad = i % 2 == 0 ? "/*\(big)*/" : ""
            wv.sdEvaluate("\(pad)window.__order.push(\(i));")
        }
        try expectEqual((read(wv, "window.__order.join(',')") as? String), "0,1,2,3,4,5")
    }

    test("sdEvaluate: a small script still runs") {
        let wv = try loadedWebView()
        wv.sdEvaluate("window.__small = 7;")
        try expectEqual((read(wv, "window.__small") as? NSNumber)?.intValue, 7)
    }
}
