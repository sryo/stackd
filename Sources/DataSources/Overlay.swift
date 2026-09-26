import AppKit
import WebKit
import CoreGraphics

// WebKit overlay primitive: a borderless click-through NSPanel hosting a
// WKWebView, pinned to a target window we don't own. The stack supplies
// {html, css?, js?}; the daemon repositions the panel to match
// SLSGetWindowBounds(targetWID) — every vsync while window events say the
// target may be changing, on a slow backstop otherwise (OverlayTickArm) —
// and, when the target's size or the outset changes, pushes
// `window.sd.target = {x,y,w,h}` into the overlay's WebView. Rendering is WebKit; the daemon only observes and sets geometry.
//
// Why NSPanel + WKWebView instead of an SLS-owned sibling window (the
// JankyBorders pattern):
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
    // Tick driving: a vsync subscription while armed, a slow backstop timer
    // otherwise. Only live between start() and stop().
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
    private var resizeDetector = LiveResizeDetector()
    private var headroom = OverlayHeadroom()
    // True after a window-server move AppKit didn't see: `panel.frame` still
    // holds the old origin until syncAppKitFrame() tells it.
    private var appKitStale: Bool = false
    private var released: Bool = false
    // Target size the panel was last fitted to; read by the event-follow
    // entry to tell a pure move from a resize.
    private var lastTargetSize: CGSize = .zero

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

    /// Stop ticking. Idempotent; detach() calls it too.
    func stop() {
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

    private func publishFollowEntry() {
        guard OverlayEventFollow.enabled, !released else { return }
        OverlayEventFollow.publish(self, OverlayFollowEntry(
            wid: UInt32(targetWID),
            panelWID: lastFrame == .zero ? 0 : UInt32(max(panel.windowNumber, 0)),
            outset: outset,
            targetSize: lastTargetSize,
            visible: panel.isVisible))
    }

    private func observe() -> Bool {
        if released { return false }
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
              let frame = Overlay.bounds(of: targetWID) else {
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
                                      resizing: resizing, now: now,
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

        let frameOp = OverlayTickPlan.frameOp(next: appKitFrame, last: lastFrame)
        let eventMoved = OverlayEventFollow.takeApplied(self)
        var reordered = false
        var alreadyMoved = false
        switch frameOp {
        case .none:
            if OverlayTickPlan.needsAppKitSync(frameOp: frameOp, appKitStale: appKitStale) {
                syncAppKitFrame()
            }
        case .move(let origin):
            if OverlayTickPlan.serverAlreadyAt(panelFrame.origin, applied: eventMoved) {
                // The event path already moved the panel there (z-order
                // untouched: a pure target move leaves it above).
                appKitStale = true
                alreadyMoved = true
            } else if moveAndOrderAboveTarget(cgsOrigin: panelFrame.origin) {
                // Straight to the window server, move + z-order in one
                // transaction: no AppKit round-trip, and no frame where the
                // panel has moved but sits below its target.
                appKitStale = true
                reordered = true
            } else {
                panel.setFrameOrigin(origin)
            }
        case .reshape(let frame):
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
            return frameChanged || unfitted
        }
        lastPushedTargetJS = js
        if navigationReady {
            pushTarget(js)
        } else {
            // Buffer — flushed in webView(_:didFinish:).
            pendingTargetJS = js
        }
        return true
    }

    private func pushTarget(_ js: String) {
        guard let now = targetPush.offer(js) else { return }
        sendTarget(now)
    }

    private func sendTarget(_ js: String) {
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self = self, !self.released else { return }
            if let next = self.targetPush.complete() { self.sendTarget(next) }
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
            webView.evaluateJavaScript(pending, completionHandler: nil)
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
        _ = commit(txRef, 0)
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

// MARK: - Overlay tick geometry (pure, testable)

/// Pure geometry for the window-tracking overlay tick — panel placement and
/// the per-tick `window.sd.target` payload, both parameterized by `outset`.
/// Separate + pure so the outset math is testable without an NSPanel.
enum OverlayGeometry {
    /// Non-finite or negative outsets fall back to 0 — a negative outset
    /// would shrink the panel INSIDE the target and, past half the target
    /// size, hand NSPanel a negative-size frame.
    static func sanitizeOutset(_ n: CGFloat) -> CGFloat {
        n.isFinite && n > 0 ? n : 0
    }

    /// Panel frame for a target window frame grown by `outset` on all four
    /// sides. Same coordinate space in as out (the tick passes CGS top-left).
    /// Outset 0 is the identity — today's pin-exactly behavior.
    static func panelFrame(target: CGRect, outset: CGFloat) -> CGRect {
        target.insetBy(dx: -outset, dy: -outset)
    }

    /// Panel frame of an explicit `size` (≥ the outset frame's) anchored
    /// top-left, so the target keeps its (outset, outset) panel position
    /// and any extra room hangs off the right and bottom. CGS top-left in
    /// and out.
    static func panelFrame(target: CGRect, outset: CGFloat, size: CGSize) -> CGRect {
        CGRect(x: target.minX - outset, y: target.minY - outset,
               width: size.width, height: size.height)
    }

    /// The {x,y,w,h,outset} object literal in PANEL coordinates — the one
    /// spelling of the payload shape shared by the per-tick push and the
    /// attach-time bootstrap seed (adding a field means editing exactly
    /// here). The target's top-left sits at (outset, outset).
    /// `resizing` is only spelled out while true, so the idle payload stays
    /// byte-identical to the pre-resizing shape (JS reads it as falsy).
    static func targetObjectJS(targetFrame: CGRect, outset: CGFloat, resizing: Bool = false) -> String {
        let o = Int(outset)
        let flag = resizing ? ",resizing:true" : ""
        return "{x:\(o),y:\(o),w:\(Int(targetFrame.width)),h:\(Int(targetFrame.height)),outset:\(o)\(flag)}"
    }

    /// The per-tick JS push. Outset 0 reproduces the legacy `{x:0,y:0,w,h}`
    /// payload plus the new `outset` field.
    static func targetPayloadJS(targetFrame: CGRect, outset: CGFloat, resizing: Bool = false) -> String {
        "window.sd=window.sd||{};window.sd.target=\(targetObjectJS(targetFrame: targetFrame, outset: outset, resizing: resizing));window.dispatchEvent(new CustomEvent('sd:target',{detail:window.sd.target}));"
    }
}

// MARK: - Live resize (pure, testable)

/// Observes whether the target is being live-resized by the user: its size
/// changed within the last `quiet` seconds while the left button is held.
/// Programmatic resizes (tilers, animations) have no button down and never
/// count. The daemon only reports the state; what to do with it (hide the
/// border, drop effects) is the stack's call.
struct LiveResizeDetector {
    static let quiet: Double = 0.060
    private var lastSize: CGSize?
    private var lastChange: Double = -.infinity

    /// `buttonDown` is only evaluated while a size change is recent, so idle
    /// ticks never query the window server.
    mutating func update(size: CGSize, now: Double, buttonDown: () -> Bool) -> Bool {
        if let last = lastSize,
           abs(last.width - size.width) >= 0.5 || abs(last.height - size.height) >= 0.5 {
            lastChange = now
        }
        lastSize = size
        guard now - lastChange < Self.quiet else { return false }
        return buttonDown()
    }
}

// MARK: - Live-resize headroom (pure, testable)

/// Panel size while the user live-resizes the target. Reshaping the panel
/// makes WebKit re-lay out and redisplay on every resize tick, so during a
/// resize the panel is rounded up with `room` to grow into, in `step`
/// increments, and only reshaped when the target outgrows it; in between,
/// resize ticks are window-server moves (or nothing). It is fitted exactly
/// once the resize has paused for `settle`. The extra room hangs off the
/// right and bottom — stacks position off `sd.target`, not the panel edge.
struct OverlayHeadroom {
    static let step: CGFloat = 128
    static let room: CGFloat = 0.5
    static let settle: Double = 0.25

    private var lastResizeAt: Double = -.infinity

    /// `content` is the exactly-fitted panel size (target plus outset),
    /// `current` the panel's size now (nil when unknown or forced).
    /// `limit` is the room from the panel's top-left to the desktop's right
    /// and bottom edges, read only when growing: room past the desktop is
    /// backing store nothing can ever draw into.
    mutating func panelSize(content: CGSize, current: CGSize?, resizing: Bool, now: Double,
                            limit: () -> CGSize? = { nil }) -> CGSize {
        if resizing { lastResizeAt = now }
        guard now - lastResizeAt < Self.settle else { return content }
        if let cur = current, content.width <= cur.width, content.height <= cur.height {
            return cur
        }
        var grown = CGSize(width: Self.roundUp(content.width * (1 + Self.room)),
                           height: Self.roundUp(content.height * (1 + Self.room)))
        if let cap = limit() {
            grown.width = max(content.width, min(grown.width, cap.width))
            grown.height = max(content.height, min(grown.height, cap.height))
        }
        return grown
    }

    private static func roundUp(_ v: CGFloat) -> CGFloat {
        (v / step).rounded(.up) * step
    }
}

// MARK: - Tick plan (pure, testable)

/// What a panel frame update costs. A move only changes the origin, so the
/// WebView's layout is untouched and no redisplay is needed; a reshape
/// resizes the web content and must go through a displaying setFrame.
enum OverlayFrameOp: Equatable {
    case none
    case move(CGPoint)
    case reshape(CGRect)
}

/// Per-tick decisions for `OverlayHandle.tick`, split out so the "skip work
/// when nothing changed" rules are testable without a panel or WebView.
enum OverlayTickPlan {
    /// `last == .zero` is the "force" sentinel (first tick, requested repin)
    /// and always yields a reshape. Sub-0.5pt jitter from CGS round-trips is
    /// treated as unchanged.
    static func frameOp(next: CGRect, last: CGRect) -> OverlayFrameOp {
        let sameOrigin = abs(next.origin.x - last.origin.x) < 0.5 &&
                         abs(next.origin.y - last.origin.y) < 0.5
        let sameSize = abs(next.width - last.width) < 0.5 &&
                       abs(next.height - last.height) < 0.5
        if sameSize && last != .zero { return sameOrigin ? .none : .move(next.origin) }
        return .reshape(next)
    }

    /// After window-server moves, AppKit's cached origin is resynced on the
    /// first tick with no frame change — never mid-motion, where it would
    /// put the AppKit round-trip back on the hot path. A reshape goes
    /// through setFrame, which resyncs by itself.
    static func needsAppKitSync(frameOp: OverlayFrameOp, appKitStale: Bool) -> Bool {
        appKitStale && frameOp == .none
    }

    /// True when the window-server event path already moved the panel to
    /// `cgsOrigin` (`applied`, CGS top-left), so the tick's own move
    /// transaction would repeat it.
    static func serverAlreadyAt(_ cgsOrigin: CGPoint, applied: CGPoint?) -> Bool {
        guard let a = applied else { return false }
        return abs(a.x - cgsOrigin.x) < 0.5 && abs(a.y - cgsOrigin.y) < 0.5
    }

    /// The payload is in panel coordinates, so it only changes on resize or
    /// outset change — never on a pure move.
    static func payloadToPush(_ js: String, lastPushed: String?) -> String? {
        js == lastPushed ? nil : js
    }
}

// MARK: - Target push (pure, testable)

/// At most one `sd.target` evaluateJavaScript in flight per overlay. A
/// resize changes the payload every vsync, and WebKit queues every eval it
/// is handed; when the web process falls behind, the backlog makes the
/// overlay replay stale sizes. Payloads offered while one is outstanding
/// replace each other, and only the newest is sent once it completes.
struct NewestWinsPush {
    private(set) var inFlight = false
    private var held: String?

    /// The payload to send now, or nil when one is already in flight (the
    /// payload is held instead, replacing any older held one).
    mutating func offer(_ js: String) -> String? {
        if inFlight {
            held = js
            return nil
        }
        inFlight = true
        return js
    }

    /// The in-flight eval finished. Returns the held payload to send next
    /// (which becomes the one in flight), or nil and goes idle.
    mutating func complete() -> String? {
        if let next = held {
            held = nil
            return next
        }
        inFlight = false
        return nil
    }
}

// MARK: - Repin policy (pure, testable)

/// Decides when a tick must re-assert the panel's z-order above its target.
///
/// Primary signal is event-driven: frame changes (move/resize/retarget) and
/// explicit repins (CGS 808 "window reordered" for the target wid, routed
/// via `Overlay.notifyWindowReordered`). The cadence is a SAFETY CEILING,
/// not the mechanism: 808 is registered per-connection in WindowEvents and
/// is yabai's canonical reorder source, but a listener that registers fine
/// can silently never fire, so we don't trust an unverified listener alone
/// for a user-visible invariant. It is measured in seconds because ticks
/// only run while armed or on the backstop; an idle overlay reorders on
/// every other backstop tick. One SLSTransactionOrderWindow per cadence is
/// a single WindowServer transaction — imperceptible cost against "border
/// silently behind its own target until the next move."
enum OverlayRepinPolicy {
    /// Chosen ceiling — raises that 808 misses stay wrong for at most this
    /// long (plus up to one backstop interval).
    static let reorderCadence: Double = 1.0

    static func shouldReorder(frameChanged: Bool, sinceReorder: Double) -> Bool {
        frameChanged || sinceReorder >= reorderCadence
    }
}

// MARK: - Tick arming (pure, testable)

/// When a window-tracking overlay runs its per-vsync tick. Each tick costs
/// two window-server reads (SLSWindowIsOrderedIn + SLSGetWindowBounds), so
/// an idle overlay shouldn't pay them every frame forever.
///
/// Events that say the target may be changing arm the tick: AX moved /
/// resized / minimized / deminimized / focused and CGS reorder / destroy
/// (through the host's window bangs), daemon-driven frame writes, retarget,
/// outset change, app hide / unhide, space and display changes. Once armed
/// the tick keeps itself alive while the frame or visibility keeps changing
/// (and while a mouse button is held, so a paused drag resumes without
/// waiting for the next coalesced AX event, or the target is mid system
/// animation, so the panel returns on the frame the animation ends), and
/// disarms after `idle` seconds of no change.
///
/// Apps that move or resize windows without posting AX notifications, and
/// windows that vanish silently, are caught by the backstop: one tick every
/// `backstopInterval` while disarmed, which arms the vsync tick as soon as
/// it sees a change. That interval is a chosen ceiling on how stale an
/// overlay can be for a target nothing tells us about.
struct OverlayTickArm {
    static let idle: Double = 0.100
    static let backstopInterval: Double = 0.5
    /// Hold for events whose visible effect lands at the end of a system
    /// animation (minimize genie, app hide, space slide).
    static let visibilityHold: Double = 0.6

    private(set) var armed = false
    private var deadline: Double = -.infinity

    var wantsBackstop: Bool { !armed }

    /// Keep ticking until at least `now + hold`. True on the disarmed →
    /// armed edge, where the caller subscribes to vsync.
    mutating func arm(now: Double, hold: Double = OverlayTickArm.idle) -> Bool {
        deadline = max(deadline, now + hold)
        if armed { return false }
        armed = true
        return true
    }

    /// After an armed tick. `changed` = the frame, visibility or payload
    /// changed this tick. `busy` = a mouse button is held or the target is
    /// mid system animation; it is only consulted once the idle spell has
    /// run out. False means disarmed: the caller unsubscribes.
    mutating func afterTick(now: Double, changed: Bool, busy: () -> Bool) -> Bool {
        if changed { deadline = max(deadline, now + Self.idle) }
        if now < deadline { return true }
        if busy() {
            deadline = now + Self.idle
            return true
        }
        armed = false
        return false
    }
}

/// Which host window bangs arm overlay ticks, and for how long. Frame and
/// z-order events arm for the idle spell (the tick then keeps itself alive
/// while the frame moves); visibility events hold through the system
/// animation that precedes the change.
enum OverlayArmEvents {
    static func hold(forBang name: String) -> Double? {
        switch name {
        case "sd.window.moved", "sd.window.resized", "sd.window.reordered",
             "sd.window.focused", "sd.window.focusedByMouse":
            return OverlayTickArm.idle
        case "sd.window.minimized", "sd.window.deminimized", "sd.window.destroyed":
            return OverlayTickArm.visibilityHold
        case "sd.window.animating":
            // The tick then stays armed for as long as the target animates
            // (OverlayTickArm.afterTick's `busy`), so it is running on the
            // frame a deminimizing window's warp ends.
            return OverlayTickArm.idle
        default:
            return nil
        }
    }
}

// MARK: - Window-server event follow (pure, testable)

/// Which overlays track which target windows. Every mutation reports
/// whether the set of distinct target wids changed, so the interest list
/// and the event filter are refreshed only when they have to be.
struct OverlayFollowTargets<Key: Hashable> {
    private var byKey: [Key: UInt32] = [:]

    /// Distinct target wids, ascending.
    var wids: [UInt32] { Array(Set(byKey.values)).sorted() }

    func contains(wid: UInt32) -> Bool { byKey.values.contains(wid) }

    /// The wid `key` currently follows; nil once detached or its target
    /// was destroyed.
    func wid(for key: Key) -> UInt32? { byKey[key] }

    /// Point `key` at `wid` (attach or retarget).
    mutating func set(_ key: Key, wid: UInt32) -> Bool {
        let before = Set(byKey.values)
        byKey[key] = wid
        return Set(byKey.values) != before
    }

    /// Forget `key` (detach).
    mutating func remove(_ key: Key) -> Bool {
        let before = Set(byKey.values)
        byKey[key] = nil
        return Set(byKey.values) != before
    }

    /// Forget every overlay on `wid` (the target was destroyed). A retarget
    /// puts the overlay back through `set`.
    mutating func drop(wid: UInt32) -> Bool {
        let keys = byKey.filter { $0.value == wid }.map { $0.key }
        for k in keys { byKey[k] = nil }
        return !keys.isEmpty
    }
}

/// What the main thread last applied for one overlay, readable from the
/// thread SkyLight delivers events on. `panelWID` 0 = no window-server
/// window yet; `targetSize` is the target size the panel was last fitted to.
struct OverlayFollowEntry: Equatable {
    var wid: UInt32
    var panelWID: UInt32
    var outset: CGFloat
    var targetSize: CGSize
    var visible: Bool
}

enum OverlayFollowAction: Equatable {
    case ignore
    /// Window-server move of the panel to this CGS top-left origin, no
    /// reorder: the panel is visible and already above its target.
    case moveNow(CGPoint)
    /// Anything that can touch AppKit or the WebView — resize, visibility,
    /// an unreadable target — runs as a full step on main.
    case stepOnMain
}

enum OverlayFollowRoute {
    /// The target wid of a 806/807, nil for any other event.
    static func frameEventWID(_ event: CGSDecodedWindowEvent) -> UInt32? {
        switch event {
        case .moved(let wid), .resized(let wid): return wid
        default: return nil
        }
    }

    /// `bounds` is SLSGetWindowBounds of the target, read after the event.
    static func action(for event: CGSDecodedWindowEvent, entry: OverlayFollowEntry,
                       bounds: CGRect?) -> OverlayFollowAction {
        guard let wid = frameEventWID(event), wid == entry.wid else { return .ignore }
        guard case .moved = event,
              entry.visible, entry.panelWID != 0,
              let b = bounds,
              abs(b.width - entry.targetSize.width) < 0.5,
              abs(b.height - entry.targetSize.height) < 0.5 else { return .stepOnMain }
        return .moveNow(CGPoint(x: b.minX - entry.outset, y: b.minY - entry.outset))
    }
}

// MARK: - Window-server event follow

/// Attached overlays follow their target on CGS 806 (moved) / 807
/// (resized) as the window server posts them, instead of on the next
/// display-link tick. The vsync tick stays armed as the backstop; this path
/// only gets there first. `STACKD_OVERLAY_EVENTS=0` turns it off: 806/807
/// stay unregistered, no interest list is set, and overlays follow on the
/// tick alone.
///
/// 806/807 only fire for wids on the connection's interest list, which
/// WindowEvents keeps at every AX-tracked window plus every overlay target
/// (see `WindowFrameInterest`). Events for windows no overlay targets are
/// counted and dropped here.
///
/// Threading: the target set is main-thread state mirrored into the
/// lock-protected `targetWIDs`/`entries`, so an event delivered off main can
/// move a visible panel at the window server directly. AppKit state
/// (`panel.frame`, the tick's lastFrame) is only touched by the main-thread
/// step each event also queues, which resyncs it; the origin moved off main
/// is kept in `applied` so that step doesn't send the same move again.
/// The main-thread step rides WindowServerIntake, which merges events per
/// wid and drains once per burst.
enum OverlayEventFollow {
    static func flagEnabled(_ env: [String: String]) -> Bool {
        env["STACKD_OVERLAY_EVENTS"] != "0"
    }

    static let enabled = flagEnabled(ProcessInfo.processInfo.environment)

    // Main thread.
    private static var targets = OverlayFollowTargets<ObjectIdentifier>()

    private static let lock = NSLock()
    private static var targetWIDs: Set<UInt32> = []
    private static var entries: [ObjectIdentifier: OverlayFollowEntry] = [:]
    private static var applied: [ObjectIdentifier: CGPoint] = [:]
    private static var stats = Stats()
    private static var threadLogged = false

    struct Stats {
        var onMain = 0
        var offMain = 0
        var forTargets = 0
        var movedOffMain = 0
        var steppedOnMain = 0
    }

    static func statsSnapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Current overlay target wids, ascending. Main thread.
    static var targetList: [UInt32] { targets.wids }

    /// Attach or retarget. Main thread.
    static func track(_ handle: OverlayHandle) {
        guard enabled else { return }
        if targets.set(ObjectIdentifier(handle), wid: UInt32(handle.targetWID)) { targetsChanged() }
    }

    /// Detach. Main thread.
    static func untrack(_ handle: OverlayHandle) {
        guard enabled else { return }
        let key = ObjectIdentifier(handle)
        lock.lock(); entries[key] = nil; applied[key] = nil; lock.unlock()
        if targets.remove(key) { targetsChanged() }
    }

    /// The target window is gone. Main thread.
    static func dropTarget(wid: CGWindowID) {
        guard enabled else { return }
        let w = UInt32(wid)
        lock.lock()
        for (key, entry) in entries where entry.wid == w {
            entries[key] = nil
            applied[key] = nil
        }
        lock.unlock()
        if targets.drop(wid: w) { targetsChanged() }
    }

    /// Record what the tick just applied, for an overlay still following
    /// that wid; a detached or destroyed-target overlay keeps no entry.
    /// Main thread.
    static func publish(_ handle: OverlayHandle, _ entry: OverlayFollowEntry) {
        guard enabled else { return }
        let key = ObjectIdentifier(handle)
        let live = targets.wid(for: key) == entry.wid
        lock.lock(); entries[key] = live ? entry : nil; lock.unlock()
    }

    /// The CGS origin the event path moved `handle`'s panel to since the
    /// last call, if any. Main thread.
    static func takeApplied(_ handle: OverlayHandle) -> CGPoint? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return applied.removeValue(forKey: ObjectIdentifier(handle))
    }

    private static func targetsChanged() {
        let wids = Set(targets.wids)
        lock.lock(); targetWIDs = wids; lock.unlock()
        WindowEvents.scheduleFrameInterestRefresh()
    }

    /// A decoded 806/807, on whatever thread SkyLight delivered it.
    static func handle(_ event: CGSDecodedWindowEvent) {
        guard enabled, let wid = OverlayFollowRoute.frameEventWID(event) else { return }
        let onMain = Thread.isMainThread
        lock.lock()
        if onMain { stats.onMain += 1 } else { stats.offMain += 1 }
        let logThread = !threadLogged
        threadLogged = true
        let isTarget = targetWIDs.contains(wid)
        if isTarget { stats.forTargets += 1 }
        let mine = onMain || !isTarget ? [] : entries.filter { $0.value.wid == wid }
        lock.unlock()
        if logThread {
            log("overlay-events: first 806/807 delivered \(onMain ? "on main" : "off main (\(Thread.current))")")
        }
        guard isTarget else { return }
        if !mine.isEmpty {
            let bounds = Overlay.bounds(of: CGWindowID(wid))
            var moved: [ObjectIdentifier: CGPoint] = [:]
            for (key, entry) in mine {
                if case .moveNow(let origin) = OverlayFollowRoute.action(for: event, entry: entry, bounds: bounds),
                   Overlay.serverMove(panelWID: entry.panelWID, cgsOrigin: origin) {
                    moved[key] = origin
                }
            }
            lock.lock()
            stats.movedOffMain += moved.count
            // Only for overlays still listed: a detach or destroy since the
            // snapshot above already dropped theirs.
            for (key, origin) in moved where entries[key] != nil { applied[key] = origin }
            lock.unlock()
        }
        WindowServerIntake.post(.window(event))
    }

    fileprivate static func countStep() {
        lock.lock(); stats.steppedOnMain += 1; lock.unlock()
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
        installArmObservers()
        OverlayEventFollow.track(handle)
    }

    /// A window-server frame event for `wid` reached main: step every
    /// overlay tracking it now, and arm its tick as the backstop.
    static func followFrameEvent(wid: CGWindowID) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.followEvent()
        }
    }

    /// CGS 804 for `wid`. Main thread.
    static func noteTargetDestroyed(wid: CGWindowID) {
        OverlayEventFollow.dropTarget(wid: wid)
    }

    /// Something about window `wid` may be changing (AX move / resize,
    /// daemon frame write, minimize, …): arm the tick of every overlay
    /// tracking it. Main thread only.
    static func noteWindowActivity(wid: CGWindowID, hold: Double = OverlayTickArm.idle) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.arm(hold: hold)
        }
    }

    /// Host window-bang tap: every `sd.window.*` bang the host fans out to
    /// stacks also arms the overlays tracking that window.
    static func noteWindowBang(name: String, detail: [String: Any]) {
        guard let hold = OverlayArmEvents.hold(forBang: name) else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { noteWindowBang(name: name, detail: detail) }
            return
        }
        if let id = detail["id"] as? Int {
            noteWindowActivity(wid: CGWindowID(id), hold: hold)
        } else {
            armAll(hold: hold)
        }
    }

    static func armAll(hold: Double = OverlayTickArm.idle) {
        for handle in liveHandles.allObjects { handle.arm(hold: hold) }
    }

    private static var armObserversInstalled = false

    /// App hide / unhide, space switches and display changes can hide,
    /// show or move any target without a per-window event. Rare, so they
    /// arm every overlay rather than resolving which targets they touched.
    /// Installed once, on the first attach, for the process lifetime.
    private static func installArmObservers() {
        if armObserversInstalled { return }
        armObserversInstalled = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                armAll(hold: OverlayTickArm.visibilityHold)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            armAll(hold: OverlayTickArm.visibilityHold)
        }
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

    /// After a screenshot session ends, ScreenshotHider re-shows every
    /// panel it hid — including overlay panels, whose direct
    /// orderFrontRegardless bypasses the vsync tick's re-show branch (the
    /// one that forceRepin()s). Fan the repin out explicitly so borders
    /// re-assert z-order above their targets on the next tick. Region
    /// overlays have no z-order tick; orderFront alone restores them.
    static func repinAllAfterScreenshot() {
        for handle in liveHandles.allObjects {
            handle.forceRepin()
        }
    }

    /// Take the panel off screen at the window server right now. AppKit's
    /// orderOut is only committed when the run loop turns, and a stack
    /// reload (display change) holds the main thread for seconds while
    /// every stack rebuilds — the old outline would sit frozen until then.
    /// AppKit's own orderOut still follows for its bookkeeping.
    static func orderOutNow(_ panel: NSPanel) {
        guard let create = WindowTransaction.create,
              let order  = WindowTransaction.orderWindow,
              let commit = WindowTransaction.commit else { return }
        let cid = SkyLight.cid
        guard cid != 0, panel.windowNumber > 0,
              let txRef = create(cid)?.takeRetainedValue() else { return }
        // Order 0 = out; the relative window is ignored.
        _ = order(txRef, UInt32(panel.windowNumber), 0, 0)
        _ = commit(txRef, 0)
    }

    /// Move the panel at the window server in one transaction, optionally
    /// ordering it one slot above `above` in the same commit. No AppKit
    /// round-trip and no redisplay, so `panel.frame` keeps the old origin
    /// until the caller resyncs it. False when the SPI is unavailable or the
    /// panel has no window-server window yet; the caller falls back to
    /// setFrameOrigin.
    static func serverMove(_ panel: NSPanel, cgsOrigin: CGPoint, above: CGWindowID? = nil) -> Bool {
        guard let create = WindowTransaction.create,
              let move   = WindowTransaction.moveWithGroup,
              let order  = WindowTransaction.orderWindow,
              let commit = WindowTransaction.commit else { return false }
        guard panel.windowNumber > 0 else { return false }
        return serverMove(panelWID: UInt32(panel.windowNumber), cgsOrigin: cgsOrigin, above: above)
    }

    /// `serverMove` by window-server id, callable off main: it touches no
    /// AppKit state, only a transaction on the shared connection.
    static func serverMove(panelWID: UInt32, cgsOrigin: CGPoint, above: CGWindowID? = nil) -> Bool {
        guard let create = WindowTransaction.create,
              let move   = WindowTransaction.moveWithGroup,
              let order  = WindowTransaction.orderWindow,
              let commit = WindowTransaction.commit else { return false }
        let cid = SkyLight.cid
        guard cid != 0, panelWID != 0,
              let txRef = create(cid)?.takeRetainedValue() else { return false }
        _ = move(txRef, panelWID, cgsOrigin)
        if let above = above {
            _ = order(txRef, panelWID, 1, UInt32(above))
        }
        return commit(txRef, 0) == 0
    }

    /// Shared NSPanel recipe for attach() and region(): borderless,
    /// transparent, click-through, never key. `frame` is AppKit coordinates.
    /// `attachedToWindow` picks the space behavior: a panel pinned to a
    /// foreign window is transient so it steps aside with Show Desktop and
    /// Mission Control along with its target; a free region stays
    /// stationary like a HUD stack.
    static func makeOverlayPanel(frame: NSRect, attachedToWindow: Bool) -> NSPanel {
        let panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .statusBar gets us above most app windows; the per-tick
        // SLSTransactionOrderWindow call explicitly pins us above the
        // specific target on the WindowServer side, which is what
        // ultimately wins for foreign-window ordering.
        panel.level = .statusBar
        // Sticky across spaces, usable over full-screen apps, never in the
        // window cycle. Region panels add .stationary (StackWindow's recipe);
        // attached panels use .transient instead, which is mutually
        // exclusive with it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
                                    attachedToWindow ? .transient : .stationary]
        panel.ignoresMouseEvents = true
        panel.unregisterDraggedTypes()
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Order-out must be immediate: an animated one needs the run loop,
        // and a stack reload (display change) blocks it for seconds while
        // every stack rebuilds — the old outline would sit frozen on screen.
        panel.animationBehavior = .none
        // Keeps the Cmd-Shift-4/5 window picker from offering the overlay
        // in place of the window beneath it. defer: false above means the
        // window-server window already exists.
        WindowServerProperty.setBool(WindowServerProperty.ignoreForScreencaptureSelection,
                                     true, on: CGWindowID(max(panel.windowNumber, 0)))
        return panel
    }

    /// Shared WKWebView recipe for overlay panels — attach() and region()
    /// build byte-identical webviews. Always drag-passthrough: every
    /// sd.overlay panel is ignoresMouseEvents=true by contract, and a
    /// drag-registered webview would make the invisible panel a Finder
    /// drag target (see PassthroughWebView).
    static func makeOverlayWebView(size: CGSize) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        let webView = PassthroughWebView(
            frame: NSRect(origin: .zero, size: size),
            configuration: config,
            dragPassthrough: true
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
        return webView
    }

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

// MARK: - Free-region overlay (fixed global rect, any display)

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
    let id: Int
    let panel: NSPanel
    let webView: WKWebView
    private var navigationReady = false
    private var pendingEvalJS: String?
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
        if navigationReady {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pendingEvalJS = (pendingEvalJS ?? "") + ";" + js
        }
    }

    /// Tear down: close the panel (drops the WKWebView). Idempotent.
    func remove() {
        if released { return }
        released = true
        Overlay.orderOutNow(panel)
        panel.orderOut(nil)
        panel.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationReady = true
        if let pending = pendingEvalJS {
            pendingEvalJS = nil
            webView.evaluateJavaScript(pending, completionHandler: nil)
        }
    }
}

extension Overlay {
    /// Create a free-region overlay at `rect` (global, top-left). Returns nil
    /// on a degenerate rect. Reuses attach()'s WKWebView + OverlayPanel recipe,
    /// minus the target/tick/reorder machinery.
    static func region(id: Int, rect: CGRect, html: String, css: String) -> RegionOverlayHandle? {
        guard let sane = RegionOverlayGeometry.sanitize(rect) else { return nil }
        let appKit = RegionOverlayGeometry.toAppKit(sane)

        let webView = makeOverlayWebView(size: appKit.size)

        let panel = makeOverlayPanel(frame: appKit, attachedToWindow: false)
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
