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

    // First-paint gate. The panel is held at alphaValue=0 from `orderFront`
    // until WKWebView's `didFinishNavigation` callback fires, then revealed
    // in one runloop tick. This replaces the old 50ms `asyncAfter` band-aid
    // that papered over the race between orderFront and first WebKit paint —
    // visible as a "flash" of empty material (especially with `.glass` /
    // `.vibrancy`) before the HTML rendered.
    //
    // Subsequent loads inside the same window (sd.window.load, JS navigation)
    // don't re-hide/re-reveal — `gate.state` stays `.revealed` after the first
    // transition. Hot-reload via FileWatcher tears down the whole StackWindow,
    // so a brand new instance gets a fresh gate.
    private var gate = FirstPaintGate()
    private var revealFallbackTimer: Timer?

    /// Maximum time we'll hold the panel hidden waiting for first paint
    /// before revealing anyway. NOT a timing-based correctness mechanism —
    /// `didFinishNavigation` (or `didFail*`) is the real signal. This is a
    /// safety net for the pathological case of a StackWindow that's ordered
    /// in but never has any content loaded into it (defensive — better to
    /// show an empty panel than to hide it forever).
    static let firstPaintFallback: TimeInterval = 2.0

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
        // drawsBackground=false stops WebKit painting; the non-opaque CALayer
        // settings below are belt-and-suspenders so the unset back-store
        // can't flash as opaque on the first frame. The primary fix for the
        // orderFront-vs-first-paint race lives in the FirstPaintGate below
        // (panel held at alphaValue=0 until didFinishNavigation).
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

        // Material backing — see `MaterialAttachment` in StackMaterial.swift for
        // the decision matrix. The crucial split: Liquid Glass needs the WebView
        // EMBEDDED inside the NSGlassEffectView's `contentView` (the SDK header
        // is explicit that sibling subviews are undefined). Vibrancy and the
        // pre-Tahoe glass fallback want the WebView as a SIBLING above an
        // NSVisualEffectView, so `blendingMode = .behindWindow` can read the
        // desktop through the transparent webview chain. `.none` with no corner
        // radius skips the container entirely.
        let supportsGlass: Bool = {
            if #available(macOS 26.0, *) { return true }
            return false
        }()
        let attachment = MaterialAttachment.mode(
            material: material, cornerRadius: cornerRadius, supportsGlass: supportsGlass)

        switch attachment {
        case .directContent:
            self.contentView = webView

        case .embeddedInGlass:
            // Guarded by `mode()`: only reached when material == .glass and
            // supportsGlass is true. The `#available` here satisfies the
            // compiler and is a no-op at runtime.
            if #available(macOS 26.0, *), case .glass(let variant) = material {
                let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
                glass.autoresizingMask = [.width, .height]
                switch variant {
                case .regular:
                    glass.style = .regular
                case .clear:
                    glass.style = .clear
                case .tinted(let color):
                    glass.style = .regular
                    glass.tintColor = color
                }
                if let r = cornerRadius, r > 0 {
                    glass.cornerRadius = CGFloat(r)
                }
                webView.frame = glass.bounds
                webView.autoresizingMask = [.width, .height]
                if let r = cornerRadius, r > 0 {
                    webView.wantsLayer = true
                    webView.layer?.cornerRadius = CGFloat(r)
                    webView.layer?.masksToBounds = true
                }
                glass.contentView = webView
                self.contentView = glass
            } else {
                self.contentView = webView  // defensive; unreachable per mode()
            }

        case .siblingInContainer:
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
        revealFallbackTimer?.invalidate()
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

    // MARK: - First-paint gating

    /// Stamp the panel hidden on the first show so the WKWebView has a
    /// chance to produce a frame before the compositor sees us. Schedules
    /// the safety-net reveal timer. Idempotent — subsequent calls are no-ops.
    private func armFirstPaintGate() {
        guard gate.shouldArmOnShow() else { return }
        self.alphaValue = 0
        revealFallbackTimer?.invalidate()
        revealFallbackTimer = Timer.scheduledTimer(
            withTimeInterval: StackWindow.firstPaintFallback, repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.gate.fallbackFired() { self.revealNow() }
        }
    }

    /// Reveal the panel and tear down the fallback timer. Called from the
    /// `didFinishNavigation` callback (first paint), `didFail*` (so a broken
    /// stack still becomes visible rather than invisible forever), or the
    /// safety-net timer.
    private func revealNow() {
        revealFallbackTimer?.invalidate()
        revealFallbackTimer = nil
        // One runloop tick of stagger — gives the just-finished navigation's
        // composited frame time to land in the back-store before the panel
        // becomes opaque. `RunLoop.main.perform` (vs `DispatchQueue.main.async`)
        // hands back to the current runloop iteration's tail, not a future one.
        RunLoop.main.perform { [weak self] in
            self?.alphaValue = 1
        }
    }

    override func orderFront(_ sender: Any?) {
        armFirstPaintGate()
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        armFirstPaintGate()
        super.orderFrontRegardless()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        armFirstPaintGate()
        super.makeKeyAndOrderFront(sender)
    }

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

    /// JS-controlled alpha. The first call permanently disables the
    /// FirstPaintGate's auto-reveal — once a stack takes manual control of
    /// alphaValue, the gate stops trying to set it to 1 (otherwise a JS call
    /// to hide the panel during init would be silently overwritten by the
    /// gate firing on `didFinishNavigation`).
    ///
    /// Used by `sd.window.setAlpha(value)` for fading HUDs (SideSwipe's
    /// volume/brightness disc, transient toasts) and any stack that needs
    /// the whole window to fade rather than the WebView contents — CSS
    /// `opacity` on body doesn't reach the NSGlassEffectView's glass layer,
    /// which renders independently of contentView alpha.
    func setAlpha(_ alpha: CGFloat) {
        gate.markOverridden()
        revealFallbackTimer?.invalidate()
        revealFallbackTimer = nil
        self.alphaValue = max(0, min(1, alpha))
    }

    /// Parse a `window.setAlpha` body into a clamped `[0, 1]` CGFloat.
    /// Returns nil for missing / non-numeric / non-finite input — the bridge
    /// then responds `false` rather than silently clamping garbage to 0.
    static func parseSetAlpha(_ body: [String: Any]) -> CGFloat? {
        guard let raw = body["value"] as? Double, raw.isFinite else { return nil }
        return CGFloat(max(0.0, min(1.0, raw)))
    }

    /// JS-controlled window frame. Input is in CG/AX convention (top-left
    /// origin, y growing down — same as `sd.windows.focused.peek().frame` and
    /// `sd.ax.attribute(.., "AXFrame")` return). The Y axis is flipped against
    /// the primary screen's height to land in AppKit coords before calling
    /// `NSWindow.setFrame`.
    ///
    /// Width / height are optional — when omitted, the current dimensions
    /// stay. Useful for stacks that reposition per-invocation (Muse anchors
    /// itself to the AX-focused element) without wanting to resize.
    func setFrame(cgX: Double, cgY: Double, w: Double?, h: Double?) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryMaxY = primary.frame.maxY
        let width  = CGFloat(w ?? Double(self.frame.width))
        let height = CGFloat(h ?? Double(self.frame.height))
        let appkitY = primaryMaxY - CGFloat(cgY) - height
        let rect = NSRect(x: CGFloat(cgX), y: appkitY, width: width, height: height)
        self.setFrame(rect, display: true)
    }

    /// Parse a `window.setFrame` body into (x, y, w?, h?). x/y required and
    /// finite; w/h optional and must be positive + finite when present.
    /// Returns nil on bad input — bridge responds false.
    static func parseSetFrame(_ body: [String: Any]) -> (x: Double, y: Double, w: Double?, h: Double?)? {
        guard let x = body["x"] as? Double, x.isFinite,
              let y = body["y"] as? Double, y.isFinite else { return nil }
        let w: Double? = (body["w"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let h: Double? = (body["h"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return (x, y, w, h)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        FileHandle.standardError.write(Data("stackd: webview did-finish \(webView.url?.absoluteString ?? "?")\n".utf8))
        webView.evaluateJavaScript("window.dispatchEvent(new Event('stackd:load'))", completionHandler: nil)
        // First-paint signal: WKWebView's CALayer has the initial frame
        // committed by the time didFinishNavigation fires. Reveal once;
        // later navigations within the same window are no-ops.
        if gate.shouldRevealOnLoadFinish() { revealNow() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("stackd: webview did-fail \(error)\n".utf8))
        // Reveal a broken stack instead of leaving it permanently hidden —
        // visible-but-empty is more debuggable than silently invisible.
        if gate.shouldRevealOnLoadFail() { revealNow() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("stackd: webview did-fail-provisional \(error)\n".utf8))
        if gate.shouldRevealOnLoadFail() { revealNow() }
    }
}

// MARK: - FirstPaintGate

/// Pure state machine for the first-paint reveal gate. Extracted from
/// StackWindow so its decision logic can be unit-tested without driving a
/// real WKWebView. Three states, monotonic forward:
///
///   .idle      — created, never shown
///   .armed     — orderFront fired, alphaValue=0, waiting for first paint
///   .revealed  — first paint (or failure / fallback) fired; stays revealed
///
/// All transitions are one-way: once revealed, every signal becomes a no-op.
/// This is what lets reloads-within-window not re-hide the panel.
struct FirstPaintGate {
    enum State { case idle, armed, revealed }
    private(set) var state: State = .idle
    private(set) var overridden: Bool = false

    /// Called from orderFront / orderFrontRegardless / makeKeyAndOrderFront.
    /// Returns true the first time only — caller should set alphaValue=0
    /// and schedule the fallback timer. Subsequent calls return false so
    /// re-ordering an already-revealed window doesn't hide it again.
    /// Once overridden by JS, never arms again — stack manages its own alpha.
    mutating func shouldArmOnShow() -> Bool {
        guard state == .idle, !overridden else { return false }
        state = .armed
        return true
    }

    /// Called from WKNavigationDelegate.didFinishNavigation. Returns true
    /// only on the transition .armed → .revealed; later navigations within
    /// the same window (e.g. JS-driven reloads) are no-ops. Returns false
    /// if JS has taken alpha control via `sd.window.setAlpha` — the stack
    /// owns visibility now, the gate stops auto-revealing.
    mutating func shouldRevealOnLoadFinish() -> Bool {
        guard state == .armed, !overridden else { return false }
        state = .revealed
        return true
    }

    /// Called from didFail / didFailProvisionalNavigation. Same transition
    /// as load-finish — we'd rather show a broken stack than a hidden one,
    /// EXCEPT when JS has taken alpha control (the stack chose its visibility
    /// state deliberately; we don't second-guess on a load error).
    mutating func shouldRevealOnLoadFail() -> Bool {
        guard state == .armed, !overridden else { return false }
        state = .revealed
        return true
    }

    /// Called when the fallback timer fires. Same transition.
    mutating func fallbackFired() -> Bool {
        guard state == .armed, !overridden else { return false }
        state = .revealed
        return true
    }

    /// Called by `StackWindow.setAlpha` — JS has taken control of alphaValue.
    /// The gate stops auto-revealing (or auto-arming on re-orderFront) so
    /// the stack's chosen alpha isn't overwritten. State transition: any →
    /// overridden (the prior state stays as-is for inspectability).
    mutating func markOverridden() {
        overridden = true
    }
}
