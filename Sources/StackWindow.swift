import AppKit
import WebKit

/// Borderless transparent NSPanel hosting a WKWebView. Stack-agnostic;
/// the stack manifest decides chrome (click-through, anchor, size).
final class StackWindow: NSPanel, WKNavigationDelegate {
    let webView: WKWebView
    let invocable: Bool

    // didMove/didResize fire during live drags + on every setFrame re-entry;
    // dedupe against the prior frame so we only emit on real geometry changes.
    private var lastObservedFrame: CGRect = .zero

    init(
        frame: NSRect,
        clickThrough: Bool,
        schemeHandler: StackdSchemeHandler,
        level: NSWindow.Level = .statusBar,
        invocable: Bool = false,
        material: StackMaterial = .none,
        cornerRadius: Double? = nil
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
        // drawsBackground=false stops WebKit painting, but the CALayer can
        // still composite white between orderFront and first paint (~50ms on
        // a fullscreen reload). Force the layer non-opaque so the unset
        // back-store doesn't flash as opaque on the first frame.
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
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
        // transparent (`.none`) and stacks render however their HTML paints.
        // With it, a system-blessed material view sits behind the WebView
        // (NSVisualEffectView for `.vibrancy`, NSGlassEffectView for `.glass`
        // on macOS 26+, NSVisualEffectView.hudWindow fallback on older OSes).
        // WebView's drawsBackground=false above lets the material show through
        // wherever the HTML hasn't painted.
        //
        // `cornerRadius` applies regardless of material — masking the WebView
        // layer rounds the rendered HTML; masking the effect layer rounds the
        // backing material so the corners are consistent.
        if case .none = material, (cornerRadius ?? 0) <= 0 {
            self.contentView = webView
        } else {
            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            if let effect = StackWindow.makeEffectView(material: material, frame: container.bounds, cornerRadius: cornerRadius) {
                container.addSubview(effect)
            }
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            if let r = cornerRadius, r > 0 {
                webView.wantsLayer = true
                webView.layer?.cornerRadius = CGFloat(r)
                webView.layer?.masksToBounds = true
            }
            container.addSubview(webView)
            self.contentView = container
        }
        webView.navigationDelegate = self

        // Pairs with stackd:load (didFinish) + stackd:unload (StackHost).
        lastObservedFrame = frame
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged(_:)),
            name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged(_:)),
            name: NSWindow.didResizeNotification, object: self)

        // Log the initial geometry — didMove/didResize only fire on changes
        // from this baseline, so creation would otherwise be invisible.
        let displayId = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
        FileHandle.standardError.write(Data(
            "stackd: stack frame init=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) display=\(displayId)\n".utf8))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func frameChanged(_ note: Notification) {
        let f = self.frame
        if f == lastObservedFrame { return }
        lastObservedFrame = f
        let displayId = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
        let name = webView.url?.host ?? "?"
        FileHandle.standardError.write(Data(
            "stackd: stack '\(name)' frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) display=\(displayId)\n".utf8))
        let js = "window.dispatchEvent(new CustomEvent('stackd:frame',{detail:{x:\(f.minX),y:\(f.minY),w:\(f.width),h:\(f.height),displayId:\(displayId)}}))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Build the backing material view (NSVisualEffectView for `.vibrancy`,
    /// NSGlassEffectView for `.glass` on macOS 26+; NSVisualEffectView with
    /// `.hudWindow` fallback on older OSes). Returns nil for `.none` — caller
    /// handles the no-backing case.
    private static func makeEffectView(material: StackMaterial, frame: NSRect, cornerRadius: Double?) -> NSView? {
        switch material {
        case .none:
            return nil
        case .vibrancy(let m):
            let v = NSVisualEffectView(frame: frame)
            v.autoresizingMask = [.width, .height]
            v.blendingMode = .behindWindow
            v.state = .active
            v.material = m
            if let r = cornerRadius, r > 0 {
                v.wantsLayer = true
                v.layer?.cornerRadius = CGFloat(r)
                v.layer?.masksToBounds = true
            }
            return v
        case .glass(let variant):
            if #available(macOS 26.0, *) {
                let g = NSGlassEffectView(frame: frame)
                g.autoresizingMask = [.width, .height]
                switch variant {
                case .regular:
                    g.style = .regular
                case .clear:
                    g.style = .clear
                case .tinted(let color):
                    g.style = .regular
                    g.tintColor = color
                }
                if let r = cornerRadius, r > 0 {
                    g.cornerRadius = CGFloat(r)
                }
                return g
            } else {
                // Pre-Tahoe fallback: hudWindow is the closest public material.
                let v = NSVisualEffectView(frame: frame)
                v.autoresizingMask = [.width, .height]
                v.blendingMode = .behindWindow
                v.state = .active
                v.material = .hudWindow
                if let r = cornerRadius, r > 0 {
                    v.wantsLayer = true
                    v.layer?.cornerRadius = CGFloat(r)
                    v.layer?.masksToBounds = true
                }
                return v
            }
        }
    }

    override var canBecomeKey: Bool { invocable }
    override var canBecomeMain: Bool { false }

    /// Show + take keyboard focus. **Never activate the stackd process** —
    /// the project rule is "stackd is never the frontmost app." The window's
    /// `.nonactivatingPanel` style mask + `canBecomeKey = true` lets this
    /// panel receive key events while the user's previous app stays visually
    /// and behaviorally frontmost. NSApp.activate(ignoringOtherApps:) was
    /// previously called here under the assumption it was necessary for key
    /// state; it's not — nonactivatingPanel is specifically designed for
    /// this case.
    func invoke() {
        makeKeyAndOrderFront(nil)
    }

    /// Hide. Doesn't deactivate the app — the user's previous frontmost
    /// app gets focus back automatically.
    func dismiss() {
        orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        FileHandle.standardError.write(Data("stackd: webview did-finish \(webView.url?.absoluteString ?? "?")\n".utf8))
        webView.evaluateJavaScript("window.dispatchEvent(new Event('stackd:load'))", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("stackd: webview did-fail \(error)\n".utf8))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("stackd: webview did-fail-provisional \(error)\n".utf8))
    }
}
