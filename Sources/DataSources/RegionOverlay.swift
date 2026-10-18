import AppKit
import WebKit
import CoreGraphics

// MARK: - Free-region overlay (fixed global rect, any display)

/// The `level` option of sd.overlay.region. Names are hs.canvas.windowLevels'
/// keys, read from the window server (CGWindowLevelForKey) rather than
/// hard-coded; a number is a raw level. Absent or unknown → `.statusBar`.
enum RegionOverlayLevel {
    static let `default` = NSWindow.Level.statusBar

    private static let keys: [String: CGWindowLevelKey] = [
        "desktop": .desktopWindow, "desktopIcon": .desktopIconWindow,
        "backstopMenu": .backstopMenu, "normal": .normalWindow,
        "floating": .floatingWindow, "tornOffMenu": .tornOffMenuWindow,
        "modalPanel": .modalPanelWindow, "utility": .utilityWindow,
        "dock": .dockWindow, "mainMenu": .mainMenuWindow,
        "status": .statusWindow, "popUpMenu": .popUpMenuWindow,
        "overlay": .overlayWindow, "help": .helpWindow,
        "dragging": .draggingWindow, "screenSaver": .screenSaverWindow,
        "assistiveTechHigh": .assistiveTechHighWindow, "cursor": .cursorWindow,
    ]

    static func resolve(_ value: Any?) -> NSWindow.Level {
        if let n = value as? NSNumber { return NSWindow.Level(rawValue: n.intValue) }
        if let s = value as? String, let key = keys[s] {
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)))
        }
        return `default`
    }
}

/// Pure geometry for the free-region overlay — validates the caller's rect and
/// converts global (top-left) coords to AppKit (bottom-left). Separate + pure
/// so the placement flip is testable without spawning an NSPanel.
enum RegionOverlayGeometry {
    /// Reject non-finite or non-positive rects before they reach NSPanel — a
    /// zero/negative/NaN size yields an invisible panel or an AppKit assert.
    static func sanitize(_ rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else { return nil }
        return rect
    }

    /// Global (top-left) → AppKit (bottom-left). One named entry point so the
    /// placement flip has a single test surface; shares OverlayHandle's recipe.
    static func toAppKit(_ globalRect: CGRect) -> CGRect {
        return OverlayHandle.cgsToAppKit(globalRect)
    }
}

/// Pure geometry for the daemon-side cursor follower (overlay.region.follow):
/// where the region panel goes when it tracks the cursor. Global top-left
/// coords throughout — the same space Mouse.location() reports and
/// RegionOverlayHandle.setFrame consumes.
enum RegionFollowGeometry {
    /// origin = cursor + offset, size unchanged. The offset is the caller's
    /// grab point (a drag ghost passes the cursor-to-window-corner delta at
    /// drag start so the ghost doesn't snap its top-left under the cursor).
    static func frame(cursor: CGPoint, offset: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: cursor.x + offset.x, y: cursor.y + offset.y,
               width: size.width, height: size.height)
    }
}

/// Live free-region overlay: a borderless click-through NSPanel + WKWebView
/// drawn at an absolute global rect on whichever display contains it. Unlike
/// `OverlayHandle` it tracks no window — no per-vsync tick, no z-order reorder.
/// Placed on create, re-placed via `setFrame`.
final class RegionOverlayHandle: NSObject, WKNavigationDelegate {
    /// Script message handler name behind the page's `window.stack.post`.
    static let messageHandlerName = "sdOverlayMessage"
    /// Defines `window.stack.post(data)` in the overlay page: hands `data`
    /// (anything structured-clonable) to the owning stack's onMessage.
    static let messageBootstrap = """
    window.stack = Object.freeze({ post(data) {
      window.webkit.messageHandlers.\(messageHandlerName).postMessage(data === undefined ? null : data);
    } });
    """

    let id: Int
    let panel: NSPanel
    let webView: WKWebView
    private var pageEval = PendingPageEval()
    private var released = false
    // Last applied frame (AppKit coords) and whether a window-server move
    // left `panel.frame` behind it — same bookkeeping as OverlayHandle.
    private var lastFrame: CGRect
    private var appKitStale = false

    init(id: Int, panel: NSPanel, webView: WKWebView) {
        self.id = id
        self.panel = panel
        self.webView = webView
        self.lastFrame = panel.frame
        super.init()
        webView.navigationDelegate = self
    }

    /// Move/resize to a new global rect. A rejected rect is ignored (the prior
    /// frame stays) rather than collapsing the panel. A same-size change is a
    /// window-server move with no redisplay (cursor follow hits this every
    /// frame); only a size change goes through AppKit's displaying setFrame.
    func setFrame(_ globalRect: CGRect) {
        if released { return }
        guard let r = RegionOverlayGeometry.sanitize(globalRect) else { return }
        let appKit = RegionOverlayGeometry.toAppKit(r)
        let op = OverlayTickPlan.frameOp(next: appKit, last: lastFrame)
        switch op {
        case .none:
            if OverlayTickPlan.needsAppKitSync(frameOp: op, appKitStale: appKitStale) { syncAppKitFrame() }
        case .move(let origin):
            if Overlay.serverMove(panel, cgsOrigin: r.origin) {
                appKitStale = true
            } else {
                panel.setFrameOrigin(origin)
            }
        case .reshape(let frame):
            panel.setFrame(frame, display: true)
            appKitStale = false
        }
        lastFrame = appKit
    }

    /// Bring AppKit's cached frame in line after window-server moves. Called
    /// once motion stops (the follow tick's first idle frame, unfollow), never
    /// mid-motion.
    func syncAppKitFrame() {
        if released || !appKitStale { return }
        panel.setFrameOrigin(lastFrame.origin)
        appKitStale = false
    }

    /// Evaluate JS in the overlay's WebView, buffering until didFinish so calls
    /// right after create still run. Mirrors `OverlayHandle.evaluate`.
    func evaluate(_ js: String) {
        if released { return }
        if let now = pageEval.offer(js) { webView.sdEvaluate(now, completionHandler: nil) }
    }

    /// Tear down: close the panel (drops the WKWebView). Idempotent.
    func remove() {
        if released { return }
        released = true
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageHandlerName)
        Overlay.orderOutNow(panel)
        panel.orderOut(nil)
        panel.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let held = pageEval.pageLoaded() { webView.sdEvaluate(held, completionHandler: nil) }
    }
}

extension Overlay {
    /// Create a free-region overlay at `rect` (global, top-left). Returns nil
    /// on a degenerate rect. Reuses attach()'s WKWebView + OverlayPanel recipe,
    /// minus the target/tick/reorder machinery.
    ///
    /// `interactive` makes the panel take real clicks, scrolls and hover
    /// (still never key, so stackd never comes frontmost); whatever sits on
    /// top of it, like a notification banner, gets its clicks first.
    /// `onMessage` receives each `window.stack.post(data)` from the page.
    static func region(id: Int, rect: CGRect, html: String, css: String,
                       level: NSWindow.Level = RegionOverlayLevel.default,
                       interactive: Bool = false,
                       onMessage: ((Any) -> Void)? = nil) -> RegionOverlayHandle? {
        guard let sane = RegionOverlayGeometry.sanitize(rect) else { return nil }
        let appKit = RegionOverlayGeometry.toAppKit(sane)

        let userContent = WKUserContentController()
        if let onMessage {
            userContent.addUserScript(WKUserScript(source: RegionOverlayHandle.messageBootstrap,
                                                   injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true))
            userContent.add(RegionOverlayMessageRelay(onMessage),
                            name: RegionOverlayHandle.messageHandlerName)
        }
        let webView = makeOverlayWebView(size: appKit.size, userContent: userContent)

        let panel = makeOverlayPanel(frame: appKit, attachedToWindow: false)
        panel.level = level
        panel.ignoresMouseEvents = !interactive
        panel.contentView = webView

        let doc = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          \(css)
        </style>
        </head><body>
        \(html)
        </body></html>
        """
        webView.loadHTMLString(doc, baseURL: nil)
        panel.orderFrontRegardless()

        return RegionOverlayHandle(id: id, panel: panel, webView: webView)
    }
}

/// WKUserContentController retains its message handlers, so the relay holds
/// only the callback; RegionOverlayHandle.remove() unregisters it.
private final class RegionOverlayMessageRelay: NSObject, WKScriptMessageHandler {
    private let onMessage: (Any) -> Void
    init(_ onMessage: @escaping (Any) -> Void) { self.onMessage = onMessage }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}
