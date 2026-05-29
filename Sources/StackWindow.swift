import AppKit
import WebKit

/// Borderless transparent NSPanel hosting a WKWebView. Stack-agnostic;
/// the stack manifest decides chrome (click-through, anchor, size).
final class StackWindow: NSPanel, WKNavigationDelegate {
    let webView: WKWebView

    init(frame: NSRect, clickThrough: Bool, schemeHandler: StackdSchemeHandler) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "sd")
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        webView = WKWebView(
            frame: NSRect(origin: .zero, size: frame.size),
            configuration: config
        )
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.ignoresMouseEvents = clickThrough
        self.isMovableByWindowBackground = false
        self.contentView = webView
        webView.navigationDelegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        FileHandle.standardError.write(Data("stackd: webview did-finish \(webView.url?.absoluteString ?? "?")\n".utf8))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("stackd: webview did-fail \(error)\n".utf8))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("stackd: webview did-fail-provisional \(error)\n".utf8))
    }
}
