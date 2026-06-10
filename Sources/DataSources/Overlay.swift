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
    /// The window this overlay currently tracks. Mutable so a single overlay
    /// can move between focused windows on focus change (overlay-border uses
    /// this pattern: one panel + WKWebView for the whole session, retargeted
    /// instead of detached + reattached, which avoids the orphan-overlay race
    /// that produced duplicate borders).
    private(set) var targetWID: CGWindowID
    let panel: NSPanel
    let webView: WKWebView

    // Last frame we positioned the overlay at. Compared on each tick to
    // skip both the AppKit setFrame and the SLSTransactionOrderWindow call
    // when nothing changed — both are server round-trips JankyBorders'
    // approach also short-circuits.
    private var lastFrame: CGRect = .zero
    // Set by forceRepin() (retarget, CGS 808 reordered-event, panel
    // re-show after the target returned from minimize). The next tick
    // treats the frame as dirty so setFrame + reorderAboveTarget both
    // re-run even when the geometry is byte-identical — the z-order can
    // be stale while the frame is not (clicking an already-focused window
    // raises it above the panel without moving it; the frame-diff
    // short-circuit alone would then never reorder and the border would
    // sit invisible behind its own target).
    private(set) var repinRequested: Bool = false
    // Ticks since the last SLSTransactionOrderWindow. Drives the
    // low-frequency safety reorder in tick() — see OverlayRepinPolicy.
    private var ticksSinceReorder: Int = 0
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

    /// Re-point this overlay at a different target window. The vsync tick
    /// driving from Bridge reads `targetWID` per frame, so the next tick
    /// fetches new SLSGetWindowBounds and repositions. Requests a repin
    /// so the position + z-order update is forced even if the new window's
    /// frame matches the prior frame coincidentally (a tile-resize cluster
    /// could land two equal-sized windows back to back).
    func setTarget(_ newWID: CGWindowID) {
        if released { return }
        if newWID == targetWID { return }
        targetWID = newWID
        forceRepin()
    }

    /// Mark the cached frame dirty so the next tick re-runs setFrame +
    /// reorderAboveTarget unconditionally. Callers (all main thread):
    /// setTarget, Overlay.notifyWindowReordered (CGS 808 for our target),
    /// and Bridge's tick closure when the panel transitions hidden→shown
    /// after the target returns from minimize — in all three cases the
    /// target's geometry may be unchanged while the z-order is stale.
    func forceRepin() {
        if released { return }
        repinRequested = true
    }

    /// Evaluate JS in the overlay's WebView. Used by stacks that drive the
    /// overlay's style from outside (overlay-border calls this on focus
    /// change to update the border color/radius). Buffers pre-didFinish.
    func evaluate(_ js: String) {
        if released { return }
        if navigationReady {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            // Append rather than replace — multiple eval calls during the
            // load window must all run on flush. pendingTargetJS already
            // does last-write-wins for target geometry; arbitrary eval is
            // append-only so style commands don't get dropped.
            let prior = pendingEvalJS ?? ""
            pendingEvalJS = prior + ";" + js
        }
    }
    private var pendingEvalJS: String?

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

        // A requested repin invalidates the frame cache so BOTH the
        // setFrame and the reorder below re-run this tick.
        if repinRequested {
            repinRequested = false
            lastFrame = .zero
        }

        let frameChanged = !rectsApproxEqual(appKitFrame, lastFrame)
        if frameChanged {
            panel.setFrame(appKitFrame, display: true)
            lastFrame = appKitFrame
        }
        // Ensure the panel sits above the target. Tag/level setup at
        // attach time covers most cases; SLSTransactionOrderWindow with
        // the target's wid as reference is the explicit "above this
        // foreign window" signal that the WindowServer honors across
        // app boundaries. Reordered on frame change, on explicit repin
        // (folded into frameChanged above), and on a low-frequency safety
        // cadence — see OverlayRepinPolicy for why the cadence exists.
        ticksSinceReorder += 1
        if OverlayRepinPolicy.shouldReorder(frameChanged: frameChanged,
                                            ticksSinceReorder: ticksSinceReorder) {
            reorderAboveTarget()
            ticksSinceReorder = 0
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
        if let pending = pendingEvalJS {
            pendingEvalJS = nil
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

// MARK: - Repin policy (pure, testable)

/// Decides when a tick must re-assert the panel's z-order above its target.
///
/// Primary signal is event-driven: frame changes (move/resize/retarget) and
/// explicit repins (CGS 808 "window reordered" for the target wid, routed
/// via `Overlay.notifyWindowReordered`). The tick cadence is a SAFETY
/// CEILING, not the mechanism: 808 is registered per-connection in
/// WindowEvents and is yabai's canonical reorder source, but per the
/// audio-processes precedent (2026-06-05: a CoreAudio listener that
/// registered fine and never fired) we don't trust an unverified listener
/// alone for a user-visible invariant. One SLSTransactionOrderWindow per
/// ~cadence is a single WindowServer transaction — imperceptible cost
/// against "border silently behind its own target until the next move."
enum OverlayRepinPolicy {
    /// ~1s at 120Hz, ~2s at 60Hz. Chosen ceiling — raises that 808 misses
    /// stay wrong for at most this long.
    static let reorderCadenceTicks = 120

    static func shouldReorder(frameChanged: Bool, ticksSinceReorder: Int) -> Bool {
        frameChanged || ticksSinceReorder >= reorderCadenceTicks
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
    /// Live handles, weakly held, for the CGS-808 reorder fan-out below.
    /// Main-thread only (attach runs on main via BridgeOverlay; 808 events
    /// hop to main in WindowEvents.handleModify). Weak table self-cleans
    /// when Bridge drops a handle; the `released` guard in forceRepin
    /// covers detached-but-not-yet-deallocated handles.
    private static let liveHandles = NSHashTable<OverlayHandle>.weakObjects()

    /// Track a handle for reorder-event fan-out. Called by attach();
    /// internal (not fileprivate) so tests can exercise
    /// notifyWindowReordered against degenerate handles.
    static func register(_ handle: OverlayHandle) {
        liveHandles.add(handle)
    }

    /// CGS 808 ("window reordered") landed for `wid`. If any live overlay
    /// targets that window, its z-order may now be stale — the classic
    /// case is clicking the already-focused window, which raises it above
    /// the panel without changing its frame, so the frame-diff
    /// short-circuit in tick() would never reorder. Request a repin; the
    /// next vsync tick re-runs setFrame + SLSTransactionOrderWindow.
    static func notifyWindowReordered(wid: CGWindowID) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.forceRepin()
        }
    }

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

        let handle = OverlayHandle(id: id, targetWID: targetID, panel: panel, webView: webView)
        register(handle)
        return handle
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
