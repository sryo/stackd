import AppKit
import WebKit
import CoreGraphics

// WebKit overlay primitive: a borderless click-through NSPanel hosting a
// WKWebView, pinned to a target window we don't own. The stack supplies
// {html, css?, js?}; per vsync the daemon repositions the panel to match
// SLSGetWindowBounds(targetWID) and pushes `window.sd.target = {x,y,w,h}`
// into the overlay's WebView. Rendering is WebKit; the daemon only observes
// and sets geometry.
//
// Why NSPanel + WKWebView instead of an SLS-owned sibling window (the
// JankyBorders pattern this file used to implement):
// - WebKit wants its own CALayer hosting tree; SLWindowContextCreate-bound
//   CGContexts don't compose with WKWebView's layers.
// - NSPanel already gives us borderless + transparent + click-through +
//   stays-across-spaces (canJoinAllSpaces + stationary + fullScreenAuxiliary
//   + ignoresCycle) — see StackWindow.swift for the same recipe.
// - We still use SLSTransactionOrderWindow to order the panel ABOVE the
//   target (a foreign-owned window) per tick, since NSWindow.level alone
//   only orders against other AppKit levels in our own connection.

// MARK: - SkyLight bindings used here

private enum SkyLightOverlay {
    typealias GetWindowBoundsFn   = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    typealias WindowIsOrderedInFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<DarwinBoolean>) -> Int32

    static let getWindowBounds:   GetWindowBoundsFn?   = SkyLight.sym("SLSGetWindowBounds")
    static let windowIsOrderedIn: WindowIsOrderedInFn? = SkyLight.sym("SLSWindowIsOrderedIn")
}

// MARK: - OverlayHandle

/// Live WebKit overlay pinned to a target window. Each handle owns:
///   - one borderless NSPanel hosting a WKWebView
///   - the target window's CGWindowID (the foreign window we follow)
///   - last-applied frame (so we only reposition / reorder on change)
final class OverlayHandle: NSObject, WKNavigationDelegate {
    let id: Int
    let targetWID: CGWindowID
    let panel: NSPanel
    let webView: WKWebView

    // Last frame we positioned the overlay at. Compared on each tick to
    // skip both the AppKit setFrame and the SLSTransactionOrderWindow call
    // when nothing changed — both are server round-trips JankyBorders'
    // approach also short-circuits.
    private var lastFrame: CGRect = .zero
    // The WKWebView only accepts evaluateJavaScript after didFinish lands.
    // Until then we buffer the latest target geometry; on finish we flush.
    private var navigationReady: Bool = false
    private var pendingTargetJS: String?
    private var released: Bool = false

    init(id: Int, targetWID: CGWindowID, panel: NSPanel, webView: WKWebView) {
        self.id = id
        self.targetWID = targetWID
        self.panel = panel
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Per-tick: reposition the panel to the target's current bounds and
    /// push `window.sd.target = {x,y,w,h}` into the overlay's WebView.
    /// `targetFrame` comes from SLSGetWindowBounds(targetWID) (top-left,
    /// screen-points).
    func tick(targetFrame: CGRect) {
        if released { return }

        // Convert CGS top-left coords to AppKit bottom-left for NSPanel.
        // The target's top edge in CGS == the panel's top edge in AppKit;
        // AppKit setFrame uses the bottom edge, so origin.y becomes
        // (screen height - targetFrame.maxY).
        let appKitFrame = OverlayHandle.cgsToAppKit(targetFrame)

        if !rectsApproxEqual(appKitFrame, lastFrame) {
            panel.setFrame(appKitFrame, display: true)
            lastFrame = appKitFrame
            // Ensure the panel sits above the target. Tag/level setup at
            // attach time covers most cases; SLSTransactionOrderWindow with
            // the target's wid as reference is the explicit "above this
            // foreign window" signal that the WindowServer honors across
            // app boundaries.
            reorderAboveTarget()
        }

        // Push target geometry into the WebView. Spec authors absolute-position
        // their elements off window.sd.target.{x,y,w,h}. (0,0) is the panel's
        // top-left, which is also the target's top-left.
        let js = "window.sd=window.sd||{};window.sd.target={x:0,y:0,w:\(Int(targetFrame.width)),h:\(Int(targetFrame.height))};window.dispatchEvent(new CustomEvent('sd:target',{detail:window.sd.target}));"
        if navigationReady {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            // Buffer — flushed in webView(_:didFinish:).
            pendingTargetJS = js
        }
    }

    /// Tear down. Closes the panel (which drops the WKWebView) and stops
    /// any in-flight evaluateJavaScript. Detaching does NOT touch the
    /// target window — we only own our panel.
    func detach() {
        if released { return }
        released = true
        panel.orderOut(nil)
        panel.close()
    }

    // WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationReady = true
        if let pending = pendingTargetJS {
            pendingTargetJS = nil
            webView.evaluateJavaScript(pending, completionHandler: nil)
        }
    }

    // MARK: - Helpers

    private func reorderAboveTarget() {
        // SLSTransactionOrderWindow(tx, panelWID, 1, targetWID) = "place
        // panelWID 1 slot above targetWID in the z-order." Works across
        // process boundaries because the WindowServer owns the global
        // order; we don't need the target's connection.
        guard let create = WindowTransaction.create,
              let order  = WindowTransaction.orderWindow,
              let commit = WindowTransaction.commit else { return }
        let cid = SkyLight.cid
        guard cid != 0 else { return }
        guard let txRef = create(cid)?.takeRetainedValue() else { return }
        let panelWID = UInt32(panel.windowNumber)
        _ = order(txRef, panelWID, 1, UInt32(targetWID))
        _ = commit(txRef, 0)
    }

    private static func cgsToAppKit(_ cgsFrame: CGRect) -> CGRect {
        // CGS uses top-left origin with y growing down; AppKit uses
        // bottom-left with y growing up. The screen height for the flip is
        // the primary display's height (NSScreen.screens[0]) — same
        // convention every other top-left → AppKit conversion in stackd
        // uses (see Windows.swift). For multi-monitor setups with the
        // primary on the right, this matches AppKit's coordinate space.
        guard let primary = NSScreen.screens.first else { return cgsFrame }
        let primaryHeight = primary.frame.maxY
        return CGRect(
            x: cgsFrame.origin.x,
            y: primaryHeight - cgsFrame.maxY,
            width: cgsFrame.width,
            height: cgsFrame.height
        )
    }

    private func rectsApproxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        // Sub-pixel jitter from AX/CG round-trips would otherwise force a
        // setFrame + reorder every tick. 0.5pt is well below "user notices."
        abs(a.origin.x - b.origin.x) < 0.5 &&
        abs(a.origin.y - b.origin.y) < 0.5 &&
        abs(a.size.width  - b.size.width)  < 0.5 &&
        abs(a.size.height - b.size.height) < 0.5
    }
}

// MARK: - Borderless transparent overlay panel

/// Borderless transparent NSPanel that hosts the overlay's WKWebView.
/// Distinct subclass (rather than reusing StackWindow) because the overlay
/// has different lifecycle needs: no sd:// scheme handler, no manifest
/// chrome, no invocable surface — just an HTML/CSS render canvas pinned
/// to a foreign window.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay (factory)

enum Overlay {
    /// Attach a new WebKit overlay pinned to `targetID`. Returns nil on
    /// allocation failure. The handle owns the NSPanel — call `detach()`
    /// to release it.
    static func attach(
        targetID: CGWindowID,
        id: Int,
        html: String,
        css: String,
        js: String
    ) -> OverlayHandle? {
        // Initial frame: 1x1 offscreen. The first tick reshapes to the
        // target's actual bounds. We can't size correctly here because
        // SLSGetWindowBounds may not be resolvable yet on a just-spawned
        // target — and even if it is, the screen-coord conversion happens
        // in tick() once we know the panel exists.
        let initialFrame = NSRect(x: -9999, y: -9999, width: 1, height: 1)

        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: initialFrame.size),
            configuration: config
        )
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.autoresizingMask = [.width, .height]

        let panel = OverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .statusBar gets us above most app windows; the per-tick
        // SLSTransactionOrderWindow call below explicitly pins us above
        // the specific target on the WindowServer side, which is what
        // ultimately wins for foreign-window ordering.
        panel.level = .statusBar
        // canJoinAllSpaces + stationary + fullScreenAuxiliary + ignoresCycle
        // match the JankyBorders SLS tag set (sticky across spaces, no
        // cmd-tab / mission-control surface). Same recipe StackWindow uses.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = webView

        let doc = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          \(css)
        </style>
        </head><body>
        \(html)
        <script>
          // Buffer for the daemon's per-vsync sd.target push. The Bridge
          // sets window.sd.target before dispatching 'sd:target'; stack
          // scripts can read either the global or the event payload.
          window.sd = window.sd || {};
          window.sd.target = { x: 0, y: 0, w: 0, h: 0 };
        </script>
        <script>
          \(js)
        </script>
        </body></html>
        """
        webView.loadHTMLString(doc, baseURL: nil)

        // Order in. NSPanel.orderFrontRegardless puts it in our app's
        // window list; the per-tick SLSTransactionOrderWindow handles the
        // cross-process z-ordering.
        panel.orderFrontRegardless()

        return OverlayHandle(id: id, targetWID: targetID, panel: panel, webView: webView)
    }

    /// Read the current bounds of a window we don't own. Top-left origin,
    /// screen-points. Returns nil if the wid is unknown or SLS rejects it.
    static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let fn = SkyLightOverlay.getWindowBounds else { return nil }
        var frame = CGRect.zero
        let err = fn(SkyLight.cid, UInt32(wid), &frame)
        return err == 0 ? frame : nil
    }

    /// Is the window currently ordered-in (visible)? Used by Bridge to
    /// suppress the per-tick reposition on minimized / hidden targets
    /// without tearing down the overlay.
    static func isOrderedIn(_ wid: CGWindowID) -> Bool {
        guard let fn = SkyLightOverlay.windowIsOrderedIn else { return false }
        var shown: DarwinBoolean = false
        _ = fn(SkyLight.cid, UInt32(wid), &shown)
        return shown.boolValue
    }
}
