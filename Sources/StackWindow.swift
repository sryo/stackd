import AppKit
import WebKit

/// Borderless transparent NSPanel hosting a WKWebView. Stack-agnostic;
/// the stack manifest decides chrome (click-through, anchor, size).
final class StackWindow: NSPanel, WKNavigationDelegate {
    let webView: WKWebView
    let invocable: Bool

    init(
        frame: NSRect,
        clickThrough: Bool,
        schemeHandler: StackdSchemeHandler,
        level: NSWindow.Level = .statusBar,
        invocable: Bool = false,
        material: String? = nil
    ) {
        self.invocable = invocable
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
        self.level = level
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.ignoresMouseEvents = clickThrough
        self.isMovableByWindowBackground = false

        // Optional native material backing. Without it the window stays pure
        // transparent (current default) and stacks use CSS backdrop-filter for
        // blur. With it, an NSVisualEffectView sits behind the WebView so the
        // window shows system-blessed material that adapts to wallpaper /
        // appearance automatically. WebView's drawsBackground=false above
        // lets the material show through wherever the HTML hasn't painted.
        if let material = material {
            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            let effect = StackWindow.makeEffectView(material: material, frame: container.bounds)
            container.addSubview(effect)
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            self.contentView = container
        } else {
            self.contentView = webView
        }
        webView.navigationDelegate = self
    }

    /// Build an NSVisualEffectView with the requested material. Manifest
    /// names map to AppKit materials; "glass" picks the closest "system glass"
    /// material per OS version (LiquidGlass arrives as a distinct NSGlassEffectView
    /// on macOS 26+ — we keep this as NSVisualEffectView until that API is
    /// stable in the SDK we ship with).
    private static func makeEffectView(material name: String, frame: NSRect) -> NSVisualEffectView {
        let v = NSVisualEffectView(frame: frame)
        v.autoresizingMask = [.width, .height]
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = {
            switch name {
            case "sidebar":  return .sidebar
            case "hud":      return .hudWindow
            case "popover":  return .popover
            case "menu":     return .menu
            case "titlebar": return .titlebar
            case "sheet":    return .sheet
            case "window":   return .windowBackground
            case "header":   return .headerView
            case "selection": return .selection
            // "glass" → hudWindow today (the most "glassy" public material);
            // promote to NSGlassEffectView once macOS 26 SDK lands.
            default:         return .hudWindow
            }
        }()
        return v
    }

    override var canBecomeKey: Bool { invocable }
    override var canBecomeMain: Bool { false }

    /// Show + take keyboard focus. Activating an LSUIElement app is the
    /// only way to actually get key state — without it, NSPanel can't
    /// become key from a background process.
    func invoke() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Hide. Doesn't deactivate the app — the user's previous frontmost
    /// app gets focus back automatically.
    func dismiss() {
        orderOut(nil)
    }

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
