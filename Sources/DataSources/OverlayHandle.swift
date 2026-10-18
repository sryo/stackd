import AppKit
import WebKit
import CoreGraphics

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
    // Points the panel extends BEYOND the target frame on every side.
    // 0 = panel pins exactly to the target (legacy behavior). A border
    // stack passes its ring thickness so the CSS border draws in the
    // outset band AROUND the window instead of covering ~thickness px of
    // window content. Survives setTarget — retargeting a border overlay
    // keeps its ring geometry.
    private(set) var outset: CGFloat = 0
    // Time of the last SLSTransactionOrderWindow. Drives the low-frequency
    // safety reorder in tick() — see OverlayRepinPolicy.
    private var lastReorderAt: Double = -.infinity
    // The target's window level, which the panel's level is derived from.
    private var targetLevel = OverlayTargetLevel()
    // Tick driving: a vsync subscription while armed, a slow backstop timer
    // otherwise. Only live between start() and detach().
    private var tickArm = OverlayTickArm()
    private var started = false
    private var linkToken: Token?
    private var backstop: Timer?
    // The WKWebView only accepts evaluateJavaScript after didFinish lands.
    // Until then we buffer the latest target geometry; on finish we flush.
    private var navigationReady: Bool = false
    private var pendingTargetJS: String?
    private var lastPushedTargetJS: String?
    private var targetPush = NewestWinsPush()
    private var reveal = OverlayRevealGate()
    // The panel frame before the last retarget, for the cross-display check
    // on the tick that places it on the new target.
    private var retargetFrom: CGRect?
    private var resizeDetector = LiveResizeDetector()
    private var headroom = OverlayHeadroom()
    // True after a window-server move AppKit didn't see: `panel.frame` still
    // holds the old origin until syncAppKitFrame() tells it.
    private var appKitStale: Bool = false
    /// When the panel last moved at the window server without AppKit.
    private var lastServerMoveAt: Double = 0
    private var released: Bool = false
    // Target size the panel was last fitted to; read by the event-follow
    // entry to tell a pure move from a resize.
    private var lastTargetSize: CGSize = .zero
    // The frame the motion engine last wrote for the target while it
    // animates it. Non-nil means the panel follows these writes instead of
    // reading the target's live bounds, which trail the write by the app's
    // AX round-trip and the compositor.
    private var commandedFrame: CGRect?
    private var trace = OverlayTrace()

    init(id: Int, targetWID: CGWindowID, panel: NSPanel, webView: WKWebView,
         outset: CGFloat = 0) {
        self.id = id
        self.targetWID = targetWID
        self.panel = panel
        self.webView = webView
        self.outset = OverlayGeometry.sanitizeOutset(outset)
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
        retargetFrom = lastFrame
        commandedFrame = nil
        OverlayEventFollow.track(self)
        forceRepin()
    }

    /// Change how far the panel extends beyond the target on every side.
    /// Requests a repin so the next tick re-runs setFrame even when the
    /// target itself hasn't moved — the panel frame derives from
    /// (target, outset), and only the outset half changed.
    func setOutset(_ n: CGFloat) {
        if released { return }
        let sane = OverlayGeometry.sanitizeOutset(n)
        if sane == outset { return }
        outset = sane
        forceRepin()
    }

    /// Mark the cached frame dirty so the next tick re-runs setFrame +
    /// reorderAboveTarget unconditionally, and arm the tick so that happens
    /// on the next vsync. Callers (all main thread): setTarget, setOutset,
    /// Overlay.notifyWindowReordered (CGS 808 for our target) and
    /// repinAllAfterScreenshot — in each case the target's geometry may be
    /// unchanged while the z-order is stale.
    func forceRepin() {
        if released { return }
        trace.note("repin")
        repinRequested = true
        arm()
    }

    // MARK: - Tick driving

    /// Begin ticking: one immediate tick to place the panel, then the
    /// backstop. Main thread only.
    func start() {
        if released || started { return }
        started = true
        let timer = Timer(timeInterval: OverlayTickArm.backstopInterval, repeats: true) { [weak self] _ in
            self?.backstopTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        backstop = timer
        arm()
    }

    /// Stop ticking. Part of detach().
    private func stop() {
        started = false
        backstop?.invalidate()
        backstop = nil
        linkToken?.cancel()
        linkToken = nil
        tickArm = OverlayTickArm()
    }

    /// Something about the target may be changing: tick every vsync until
    /// it has been quiet for `hold` (at least OverlayTickArm.idle).
    func arm(hold: Double = OverlayTickArm.idle) {
        if released || !started { return }
        guard tickArm.arm(now: CFAbsoluteTimeGetCurrent(), hold: hold) else { return }
        // subscribe() primes the callback synchronously, so the first armed
        // tick runs before the token is stored.
        let token = DisplayLinkObserver.shared.subscribe { [weak self] in self?.armedTick() }
        if tickArm.armed && started { linkToken = token } else { token.cancel() }
    }

    private func armedTick() {
        let changed = step()
        let stay = tickArm.afterTick(now: CFAbsoluteTimeGetCurrent(), changed: changed,
                                     busy: { [targetWID] in
                                         Mouse.isLeftButtonDown()
                                             || WindowEvents.isAnimating(windowID: targetWID)
                                     })
        if !stay {
            linkToken?.cancel()
            linkToken = nil
        }
    }

    private func backstopTick() {
        guard tickArm.wantsBackstop else { return }
        if step() { arm() }
    }

    /// One observation of the target: hide the panel when the target is
    /// gone or hidden, re-show it when it returns, otherwise follow its
    /// frame. True when anything visible changed.
    @discardableResult
    func step() -> Bool {
        let changed = observe()
        publishFollowEntry()
        return changed
    }

    /// A window-server move/resize for the target reached main: step now
    /// rather than on the next vsync, and keep the tick armed behind it.
    func followEvent() {
        if released || !started { return }
        OverlayEventFollow.countStep()
        step()
        arm()
    }

    /// The target app just applied `frame`, written by the motion engine:
    /// place the panel there now, ahead of the window server's report.
    func followCommanded(_ frame: CGRect) {
        if released || !started { return }
        trace.note("commanded")
        commandedFrame = frame
        step()
        arm()
    }

    /// The target's animation ended or was cancelled: go back to reading its
    /// live bounds, which the armed tick does from the next vsync on.
    func releaseCommanded() {
        guard commandedFrame != nil else { return }
        commandedFrame = nil
        publishFollowEntry()
        arm()
    }

    private func publishFollowEntry() {
        guard OverlayEventFollow.enabled, !released else { return }
        OverlayEventFollow.publish(self, OverlayFollowEntry(
            wid: UInt32(targetWID),
            panelWID: lastFrame == .zero ? 0 : UInt32(max(panel.windowNumber, 0)),
            outset: outset,
            targetSize: lastTargetSize,
            visible: panel.isVisible,
            commanded: commandedFrame != nil))
    }

    private func observe() -> Bool {
        if released { return false }
        let traceStart = CFAbsoluteTimeGetCurrent()
        defer { trace.tickEnded(start: traceStart) }
        // Screenshot session in progress: ScreenshotHider ordered the panel
        // out; the re-show branch below would undo that one frame later.
        // Stay dormant — the hider's restore + repinAllAfterScreenshot
        // handle z-order on session exit.
        if ScreenshotHider.shared.active { return false }
        // Target gone, hidden (closed / minimized / cmd-H'd) or mid system
        // animation: hide the panel rather than leave a ghost border at the
        // last frame. During the genie SkyLight still reports the window
        // ordered in at its unwarped frame.
        guard Overlay.isOrderedIn(targetWID),
              !WindowEvents.isAnimating(windowID: targetWID),
              let frame = OverlayFrameSource.targetFrame(
                  commanded: commandedFrame, live: { Overlay.bounds(of: targetWID) }) else {
            if panel.isVisible {
                panel.orderOut(nil)
                return true
            }
            return false
        }
        var changed = false
        if !panel.isVisible {
            syncAppKitFrame()
            panel.orderFrontRegardless()
            trace.note("reshow")
            // The target may have returned at its exact old frame (un-
            // minimize restores geometry), so the frame diff alone would
            // skip the SLS reorder and leave the panel below it.
            repinRequested = true
            changed = true
        }
        return tick(targetFrame: frame) || changed
    }

    /// Evaluate JS in the overlay's WebView. Used by stacks that drive the
    /// overlay's style from outside (overlay-border calls this on focus
    /// change to update the border color/radius). Buffers pre-didFinish.
    func evaluate(_ js: String) {
        if released { return }
        if navigationReady {
            webView.sdEvaluate(js, completionHandler: nil)
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

    /// Per-tick: reposition the panel to the target's current bounds
    /// (grown by `outset` on all sides) and, when it changed, push
    /// `window.sd.target = {x,y,w,h,outset}` in PANEL coordinates into the
    /// overlay's WebView. During a live resize the panel may be larger than
    /// that (see OverlayHeadroom); the target still sits at (outset, outset).
    /// `targetFrame` comes from SLSGetWindowBounds(targetWID) (top-left,
    /// screen-points). True when anything changed, or while the panel still
    /// has to be fitted after a resize.
    @discardableResult
    func tick(targetFrame: CGRect) -> Bool {
        if released { return false }
        let now = CFAbsoluteTimeGetCurrent()

        // A repin re-reads the target's level; a retarget reads the new
        // target's.
        applyPanelLevel(refresh: repinRequested)

        // A requested repin invalidates the frame cache so BOTH the
        // setFrame and the reorder below re-run this tick.
        if repinRequested {
            repinRequested = false
            lastFrame = .zero
        }

        lastTargetSize = targetFrame.size
        let resizing = resizeDetector.update(size: targetFrame.size, now: now,
                                             buttonDown: Mouse.isLeftButtonDown)
        let fitted = OverlayGeometry.panelFrame(target: targetFrame, outset: outset).size
        let size = headroom.panelSize(content: fitted,
                                      current: lastFrame == .zero ? nil : lastFrame.size,
                                      resizing: OverlayTickPlan.holdsHeadroom(liveResize: resizing,
                                                                               commanded: commandedFrame != nil),
                                      now: now,
                                      limit: { OverlayHandle.roomToDesktopEdge(from: CGPoint(
                                          x: targetFrame.minX - self.outset,
                                          y: targetFrame.minY - self.outset)) })
        // Convert CGS top-left coords to AppKit bottom-left for NSPanel.
        // The target's top edge in CGS == the panel's top edge in AppKit;
        // AppKit setFrame uses the bottom edge, so origin.y becomes
        // (screen height - panelFrame.maxY).
        let panelFrame = OverlayGeometry.panelFrame(target: targetFrame, outset: outset, size: size)
        let appKitFrame = OverlayHandle.cgsToAppKit(panelFrame)
        let unfitted = size != fitted
        if let from = retargetFrom {
            retargetFrom = nil
            let repaints = OverlayScreens.retargetRepaints(from: from, to: appKitFrame,
                                                            screens: NSScreen.screens.map(\.frame))
            if reveal.retargeted(repaints: repaints) { hideUntilPainted() }
        }

        let frameOp = OverlayTickPlan.frameOp(next: appKitFrame, last: lastFrame)
        let eventMoved = OverlayEventFollow.takeApplied(self)
        var reordered = false
        var alreadyMoved = false
        switch frameOp {
        case .none:
            if OverlayTickPlan.needsAppKitSync(frameOp: frameOp, appKitStale: appKitStale,
                                               sinceLastServerMove: now - lastServerMoveAt) {
                syncAppKitFrame()
            }
        case .move(let origin):
            if OverlayTickPlan.serverAlreadyAt(panelFrame.origin, applied: eventMoved) {
                // The event path already moved the panel there (z-order
                // untouched: a pure target move leaves it above).
                appKitStale = true
                lastServerMoveAt = now
                alreadyMoved = true
                trace.note("event-moved")
            } else if moveAndOrderAboveTarget(cgsOrigin: panelFrame.origin) {
                trace.note("move+order")
                // Straight to the window server, move + z-order in one
                // transaction: no AppKit round-trip, and no frame where the
                // panel has moved but sits below its target.
                appKitStale = true
                lastServerMoveAt = now
                reordered = true
            } else {
                trace.note("setFrameOrigin")
                panel.setFrameOrigin(origin)
            }
        case .reshape(let frame):
            trace.note("reshape")
            panel.setFrame(frame, display: true)
            appKitStale = false
        }
        let frameChanged = frameOp != .none
        if frameChanged { lastFrame = appKitFrame }
        // Ensure the panel sits above the target. Tag/level setup at
        // attach time covers most cases; SLSTransactionOrderWindow with
        // the target's wid as reference is the explicit "above this
        // foreign window" signal that the WindowServer honors across
        // app boundaries. Reordered on frame change, on explicit repin
        // (folded into frameChanged above), and on a low-frequency safety
        // cadence — see OverlayRepinPolicy for why the cadence exists.
        if reordered {
            lastReorderAt = now
        } else if !alreadyMoved, OverlayRepinPolicy.shouldReorder(frameChanged: frameChanged,
                                                   sinceReorder: now - lastReorderAt) {
            reorderAboveTarget()
            trace.note("reorder")
            lastReorderAt = now
        }

        // Push target geometry into the WebView. Spec authors absolute-position
        // their elements off window.sd.target.{x,y,w,h,outset} — panel
        // coordinates, so the target's top-left sits at (outset, outset).
        // With outset 0 that's (0,0), byte-compatible with the pre-outset
        // payload plus the new field.
        let payload = OverlayGeometry.targetPayloadJS(targetFrame: targetFrame, outset: outset,
                                                      resizing: resizing)
        guard let js = OverlayTickPlan.payloadToPush(payload, lastPushed: lastPushedTargetJS) else {
            confirmPaintIfHidden()
            return frameChanged || unfitted
        }
        lastPushedTargetJS = js
        if navigationReady {
            pushTarget(js)
        } else {
            // Buffer — flushed in webView(_:didFinish:).
            pendingTargetJS = js
        }
        confirmPaintIfHidden()
        return true
    }

    /// Only for a page that never answers the paint confirm. Under heavy
    /// system load the confirm itself takes a few hundred ms, and revealing
    /// before it shows the stale border this gate exists to hide.
    private static let revealFallback: TimeInterval = 1.0

    private func hideUntilPainted() {
        panel.alphaValue = 0
        trace.note("hide-until-painted")
        guard let gen = reveal.hiddenGeneration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealFallback) { [weak self] in
            guard let self = self, !self.released else { return }
            if self.reveal.fallback(generation: gen) { self.panel.alphaValue = 1 }
        }
    }

    /// Once the new target geometry has reached the page, wait for two
    /// animation frames there — the second fires only after the first
    /// painted frame at the new size and scale was committed — then reveal.
    private func confirmPaintIfHidden() {
        guard navigationReady,
              let gen = reveal.confirmation(pushInFlight: targetPush.inFlight) else { return }
        webView.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
            arguments: [:], in: nil, in: .page
        ) { [weak self] _ in
            guard let self = self, !self.released else { return }
            if self.reveal.confirmed(generation: gen) { self.panel.alphaValue = 1 }
        }
    }

    private func pushTarget(_ js: String) {
        guard let now = targetPush.offer(js) else { return }
        sendTarget(now)
    }

    private func sendTarget(_ js: String) {
        webView.sdEvaluate(js) { [weak self] _, _ in
            guard let self = self, !self.released else { return }
            if let next = self.targetPush.complete() { self.sendTarget(next) }
            else { self.confirmPaintIfHidden() }
        }
    }

    /// Tear down. Closes the panel (which drops the WKWebView) and stops
    /// any in-flight evaluateJavaScript. Detaching does NOT touch the
    /// target window — we only own our panel.
    func detach() {
        if released { return }
        stop()
        released = true
        OverlayEventFollow.untrack(self)
        Overlay.orderOutNow(panel)
        panel.orderOut(nil)
        panel.close()
    }

    // WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationReady = true
        if let pending = pendingTargetJS {
            pendingTargetJS = nil
            pushTarget(pending)
        }
        if let pending = pendingEvalJS {
            pendingEvalJS = nil
            webView.sdEvaluate(pending, completionHandler: nil)
        }
    }

    // MARK: - Helpers

    /// Bring AppKit's cached frame in line with where the window server has
    /// the panel. The server-side move is a no-op (the panel is already
    /// there); this only keeps AppKit from later restoring the stale origin.
    func syncAppKitFrame() {
        guard appKitStale, lastFrame != .zero else { return }
        panel.setFrameOrigin(lastFrame.origin)
        appKitStale = false
    }

    /// Put the panel at the level OverlayTargetLevel.panelLevel picks for
    /// its target. Only writes on change, which for a normal-level target is
    /// never after attach. The write reaches the window server at AppKit's
    /// next commit; nothing here waits for it, since the panel is above the
    /// target's level wherever it lands inside its own.
    private func applyPanelLevel(refresh: Bool) {
        let target = targetLevel.resolve(target: targetWID, refresh: refresh,
                                         read: { Overlay.level(of: $0) })
        let raw = OverlayTargetLevel.panelLevel(above: target)
        if panel.level.rawValue != raw {
            trace.note("level \(panel.level.rawValue)->\(raw)")
            panel.level = NSWindow.Level(rawValue: raw)
        }
    }

    private func moveAndOrderAboveTarget(cgsOrigin: CGPoint) -> Bool {
        Overlay.serverMove(panel, cgsOrigin: cgsOrigin, above: targetWID)
    }

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
        commit(txRef, 0)
    }

    /// Width and height from `cgsPoint` to the right and bottom edges of the
    /// union of all displays (CGS top-left coords). nil without screens.
    static func roomToDesktopEdge(from cgsPoint: CGPoint) -> CGSize? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let primaryHeight = primary.frame.maxY
        let desktop = screens.reduce(CGRect.null) { acc, screen in
            let f = screen.frame
            return acc.union(CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height))
        }
        return CGSize(width: desktop.maxX - cgsPoint.x, height: desktop.maxY - cgsPoint.y)
    }

    static func cgsToAppKit(_ cgsFrame: CGRect) -> CGRect {
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
}

extension Overlay {
    /// Attach a new WebKit overlay pinned to `targetID`. Returns nil on
    /// allocation failure. The handle owns the NSPanel — call `detach()`
    /// to release it.
    static func attach(
        targetID: CGWindowID,
        id: Int,
        html: String,
        css: String,
        js: String,
        outset: CGFloat = 0
    ) -> OverlayHandle? {
        // Initial frame: 1x1 offscreen. The first tick reshapes to the
        // target's actual bounds. We can't size correctly here because
        // SLSGetWindowBounds may not be resolvable yet on a just-spawned
        // target — and even if it is, the screen-coord conversion happens
        // in tick() once we know the panel exists.
        let initialFrame = NSRect(x: -9999, y: -9999, width: 1, height: 1)

        let webView = makeOverlayWebView(size: initialFrame.size)

        let panel = makeOverlayPanel(frame: initialFrame, attachedToWindow: true)
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
          // Panel coords: the target's top-left is at (outset, outset).
          window.sd = window.sd || {};
          window.sd.target = \(OverlayGeometry.targetObjectJS(targetFrame: .zero, outset: OverlayGeometry.sanitizeOutset(outset)));
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

        let handle = OverlayHandle(id: id, targetWID: targetID, panel: panel,
                                   webView: webView, outset: outset)
        register(handle)
        return handle
    }
}
