import WebKit

/// Size gate for `WKWebView.sdEvaluate`.
///
/// A script source past roughly 32 KB makes WebKit ship the evaluateJavaScript
/// message out-of-line, and the host process never frees that buffer: it shows
/// up as "Owned physical footprint (unmapped)" in `footprint`, one region per
/// call, forever. The same bytes passed as a callAsyncJavaScript *argument*
/// are freed. 8 KB leaves headroom under the observed threshold while keeping
/// every hot-path push (channel deltas, responses, overlay targets) on plain
/// evaluateJavaScript.
enum WebViewEval {
    static let inlineLimit = 8 * 1024
}

extension WKWebView {
    /// `evaluateJavaScript` that doesn't leak on large scripts. Oversized
    /// sources run through an indirect `eval` inside callAsyncJavaScript,
    /// which keeps classic-script semantics (global scope, top-level `var`
    /// lands on window) and returns the script's completion value.
    func sdEvaluate(_ script: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        if script.utf8.count <= WebViewEval.inlineLimit {
            evaluateJavaScript(script, completionHandler: completionHandler)
            return
        }
        callAsyncJavaScript("return (0, eval)(s)", arguments: ["s": script],
                            in: nil, in: .page) { result in
            guard let completionHandler = completionHandler else { return }
            switch result {
            case .success(let value): completionHandler(value, nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
    }
}
