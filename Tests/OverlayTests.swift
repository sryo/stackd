import Foundation
import AppKit
import CoreGraphics
import WebKit

// Tests for `Sources/DataSources/Overlay.swift`.
//
// Overlay.swift is a WebKit overlay primitive: a borderless click-through
// NSPanel hosting a WKWebView, pinned to a foreign target window via the
// private SkyLight (CGS) SPI. Bridge wires it to two custom verbs —
// `overlay.attach` / `overlay.detach` (Sources/Bridge.swift:1822-1869) —
// and one per-vsync read pair (`isOrderedIn` + `bounds(of:)`) that drives
// the reposition tick.
//
// What CAN be characterized without mutating live macOS state or spawning
// an AppKit window:
//
//   1. `Overlay.bounds(of:)` — wraps SLSGetWindowBounds. For an obviously-
//      invalid CGWindowID (0 == kCGNullWindowID) the SPI returns non-zero
//      and the wrapper bails to nil. The Bridge tick (Bridge.swift:1853)
//      relies on this: an overlay whose target is stale gets skipped
//      cleanly instead of repositioning to garbage geometry.
//
//   2. `Overlay.isOrderedIn(_:)` — wraps SLSWindowIsOrderedIn. For an
//      invalid wid the SPI doesn't populate the out-param, the wrapper's
//      DarwinBoolean default is `false`, and the Bridge tick short-circuits
//      before calling bounds(). Locks the "stale wid → false, never crash"
//      contract that the per-vsync subscription depends on.
//
//   3. Return-type contracts — JS consumers (and Bridge's NSNull-wrapping
//      respond path) depend on `bounds` being CGRect? and `isOrderedIn`
//      being Bool, deterministically, even on miss. Idempotence matters
//      too: the same invalid id called repeatedly must keep returning the
//      same value (no internal cache that flips state).
//
// What is NOT covered here (by design):
//
//   - `Overlay.attach(...)` — creates a WKWebViewConfiguration, a WKWebView,
//     and an OverlayPanel (NSPanel subclass), then calls
//     `orderFrontRegardless()`. NSWindow / NSPanel construction requires
//     NSApp + the main thread; the test harness has neither. Even if we
//     wired NSApplication.shared, the panel would surface as a visible
//     borderless window during the suite run — explicitly out of scope per
//     the test-author constraints.
//
//   - `OverlayHandle.tick(targetFrame:)` / `detach()` — both touch the
//     real NSPanel that attach() owns. Same NSApp dependency.
//
//   - `OverlayHandle.cgsToAppKit` / `rectsApproxEqual` — both `private`
//     (one static, one instance). The test target can't reach them and we
//     don't widen production visibility just to test them. The coordinate
//     flip is exercised indirectly the moment attach() ships (every other
//     CGS-top-left → AppKit-bottom-left site in stackd uses the same recipe;
//     see Windows.swift).
//
//   - `OverlayPanel` (private NSPanel subclass) — same reasons as attach().
//
//   - The WKNavigationDelegate flush (`webView(_:didFinish:)`) — fires off
//     the WebKit loader; requires a real loadHTMLString lifecycle, which
//     means a real WKWebView, which means main thread + NSApp.
//
// Pattern mirrors WindowsTests + AppsTests: SPI-coupled readers get
// negative-input contract pinning on an obviously-invalid wid so the
// per-vsync subscription in Bridge.swift stays deterministic across
// minimize / close / target-already-gone races.

func registerOverlayTests() {
    // MARK: - Overlay.bounds(of:) — negative branch for invalid CGWindowID

    test("Overlay.bounds returns nil for kCGNullWindowID") {
        // CGWindowID 0 is reserved (kCGNullWindowID) and never names a real
        // window. SLSGetWindowBounds rejects it with a non-zero error; the
        // wrapper translates that to nil. Bridge's per-vsync tick
        // (Bridge.swift:1853) uses this to skip overlays whose target has
        // disappeared without tearing them down.
        try expect(Overlay.bounds(of: 0) == nil,
                   "expected nil bounds for wid 0 (kCGNullWindowID)")
    }

    test("Overlay.bounds is idempotent for an invalid wid") {
        // No hidden cache that flips state between calls. The vsync
        // subscription calls bounds() at display refresh rate; a one-shot
        // nil that became non-nil on retry would cause the overlay to
        // teleport once per missed frame.
        try expect(Overlay.bounds(of: 0) == nil)
        try expect(Overlay.bounds(of: 0) == nil)
        try expect(Overlay.bounds(of: 0) == nil)
    }

    test("Overlay.bounds tolerates assorted obviously-invalid wids") {
        // Bridge hands CGWindowID(Int) straight through from JS — anything
        // can land here. The wrapper must short-circuit (not crash) on
        // values WindowServer will never assign to a real window.
        try expect(Overlay.bounds(of: CGWindowID(0)) == nil)
        try expect(Overlay.bounds(of: CGWindowID.max) == nil,
                   "expected nil bounds for UInt32.max (never a real wid)")
    }

    // MARK: - Overlay.isOrderedIn(_:) — negative branch for invalid CGWindowID

    test("Overlay.isOrderedIn returns false for kCGNullWindowID") {
        // SLSWindowIsOrderedIn doesn't populate `shown` for an unknown wid;
        // the DarwinBoolean default of `false` is what callers see. The
        // tick subscription guards on this BEFORE calling bounds(), so a
        // false return is the documented "skip this tick" signal.
        try expectEqual(Overlay.isOrderedIn(0), false)
    }

    test("Overlay.isOrderedIn is idempotent for an invalid wid") {
        // Same per-vsync stability concern as bounds(). A flipping result
        // would cause the overlay to repeatedly enter / exit the
        // reposition branch in Bridge.swift:1852-1854.
        try expectEqual(Overlay.isOrderedIn(0), false)
        try expectEqual(Overlay.isOrderedIn(0), false)
        try expectEqual(Overlay.isOrderedIn(0), false)
    }

    test("Overlay.isOrderedIn returns false for UInt32.max") {
        // Out-of-range wid: SkyLight rejects it, the wrapper returns the
        // DarwinBoolean default. Locks the "Bool, never null, never crash"
        // contract that the JS-visible side of Bridge depends on.
        try expectEqual(Overlay.isOrderedIn(CGWindowID.max), false)
    }

    // MARK: - bounds + isOrderedIn together — the tick guard pair

    // MARK: - OverlayHandle.setTarget — retarget mutation

    test("OverlayHandle.setTarget updates targetWID and is idempotent for the same wid") {
        // setTarget exists so overlay-border can move ONE overlay between
        // focused windows on focus change, instead of detach+attach pairs
        // racing on the daemon main thread and leaving duplicate panels on
        // screen. The vsync ticker reads targetWID per frame, so all we
        // need from this method is that the property actually changes.
        //
        // Construct a degenerate panel + webView pair on the main thread.
        // No orderFront → nothing visible during the suite. Same constraint
        // as the rest of the harness: we exercise the mutation without
        // mounting AppKit windows.
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 1, targetWID: 100, panel: panel, webView: webView)
        try expectEqual(h.targetWID, CGWindowID(100))
        h.setTarget(200)
        try expectEqual(h.targetWID, CGWindowID(200))
        h.setTarget(200)  // idempotent — early-out path
        try expectEqual(h.targetWID, CGWindowID(200))
        // Cleanup — panel/webView drop with the test scope.
        h.detach()
    }

    test("OverlayHandle.setTarget on a detached handle is a safe no-op") {
        // Race: a focus change can fire while the handle is being torn down
        // (stack reload). The released guard must catch it so we don't
        // silently apply a target to a closed panel — the next tick would
        // read targetWID and try to reposition a deallocated WebView.
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 2, targetWID: 100, panel: panel, webView: webView)
        h.detach()
        h.setTarget(300)
        try expectEqual(h.targetWID, CGWindowID(100),
                        "expected targetWID unchanged after detach + setTarget")
    }

    // MARK: - OverlayRepinPolicy — z-order re-assert decision (pure)

    test("OverlayRepinPolicy reorders on frame change regardless of tick count") {
        // Frame changed = the target moved/resized/retargeted. The reorder
        // must ride along every time — this is the event-driven primary.
        try expectEqual(OverlayRepinPolicy.shouldReorder(frameChanged: true, ticksSinceReorder: 0), true)
        try expectEqual(OverlayRepinPolicy.shouldReorder(frameChanged: true, ticksSinceReorder: 1), true)
    }

    test("OverlayRepinPolicy holds off below the cadence when the frame is static") {
        // Static frame + recent reorder → skip the WindowServer round-trip.
        // This is the short-circuit that keeps the per-vsync tick cheap.
        try expectEqual(
            OverlayRepinPolicy.shouldReorder(
                frameChanged: false,
                ticksSinceReorder: OverlayRepinPolicy.reorderCadenceTicks - 1),
            false)
        try expectEqual(OverlayRepinPolicy.shouldReorder(frameChanged: false, ticksSinceReorder: 0), false)
    }

    test("OverlayRepinPolicy fires the safety reorder at the cadence ceiling") {
        // Regression pin for the "border invisible behind its own target"
        // bug: clicking an already-focused window raises it above the panel
        // WITHOUT changing its frame, so the frame-diff alone never
        // reordered again. CGS 808 → forceRepin is the event-driven fix;
        // this cadence is the documented ceiling if 808 ever goes quiet
        // (audio-processes precedent: registered listeners that never fire).
        try expectEqual(
            OverlayRepinPolicy.shouldReorder(
                frameChanged: false,
                ticksSinceReorder: OverlayRepinPolicy.reorderCadenceTicks),
            true)
        // Cadence must stay low-frequency-but-finite: more than a handful
        // of frames (not a per-tick hammer), bounded so staleness self-heals.
        try expect(OverlayRepinPolicy.reorderCadenceTicks > 10,
                   "cadence this low would reorder nearly every tick")
        try expect(OverlayRepinPolicy.reorderCadenceTicks <= 600,
                   "cadence this high leaves a wrong z-order visible for 5s+ at 120Hz")
    }

    // MARK: - OverlayHandle.forceRepin — explicit z-order invalidation

    test("OverlayHandle.forceRepin marks the handle and setTarget implies it") {
        // forceRepin is how CGS 808 (window reordered) and the panel
        // re-show path tell the next tick "your cached frame comparison is
        // a lie — re-run setFrame + reorder even if geometry is identical."
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 3, targetWID: 100, panel: panel, webView: webView)
        try expectEqual(h.repinRequested, false, "fresh handle must not start dirty")
        h.forceRepin()
        try expectEqual(h.repinRequested, true)
        // Retarget must also force the repin — two equal-sized tiled
        // windows back to back would otherwise skip both setFrame and
        // reorder on the swap. Own panel: each detach closes its panel
        // exactly once (NSWindow double-close is an ARC over-release).
        let panel2 = NSPanel(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: true)
        let h2 = OverlayHandle(id: 4, targetWID: 100, panel: panel2,
                               webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        h2.setTarget(200)
        try expectEqual(h2.repinRequested, true, "setTarget must request a repin")
        h.detach()
        h2.detach()
    }

    test("OverlayHandle.forceRepin on a detached handle is a safe no-op") {
        // Same teardown race as setTarget: a CGS 808 can land while the
        // stack reload is draining handles. The released guard must hold.
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 5, targetWID: 100, panel: panel, webView: webView)
        h.detach()
        h.forceRepin()
        try expectEqual(h.repinRequested, false,
                        "detached handle must not accept repin requests")
    }

    // MARK: - Overlay.notifyWindowReordered — CGS 808 fan-out

    test("Overlay.notifyWindowReordered repins only handles targeting that wid") {
        // The 808 callback fires for EVERY reorder system-wide; only the
        // overlay pinned to the reordered window has a stale z-order.
        // Per-handle panels: detach closes the panel, and closing the same
        // NSPanel twice is an ARC over-release.
        let panelA = NSPanel(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: true)
        let panelB = NSPanel(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: true)
        let onTarget  = OverlayHandle(id: 6, targetWID: 7001, panel: panelA,
                                      webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        let offTarget = OverlayHandle(id: 7, targetWID: 7002, panel: panelB,
                                      webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        Overlay.register(onTarget)
        Overlay.register(offTarget)
        Overlay.notifyWindowReordered(wid: 7001)
        try expectEqual(onTarget.repinRequested, true,
                        "handle targeting the reordered wid must repin")
        try expectEqual(offTarget.repinRequested, false,
                        "unrelated handle must not pay the reorder round-trip")
        // Cleanup so later notify tests in this process don't see these.
        onTarget.detach()
        offTarget.detach()
    }

    test("Overlay.notifyWindowReordered with no registered handles is safe") {
        // Boot order: WindowEvents can deliver an 808 before any stack has
        // attached an overlay. Must be a clean no-op.
        Overlay.notifyWindowReordered(wid: 12345)
    }

    test("bounds and isOrderedIn agree on an invalid wid (both negative)") {
        // The per-vsync subscription in Bridge.swift checks `isOrderedIn`
        // first, then `bounds`. For an invalid wid both must short-circuit
        // to their negative return so the tick exits cleanly. If they
        // disagreed (e.g. isOrderedIn=true, bounds=nil) the guard would
        // still bail thanks to the `let frame =` requirement, but the
        // contract is "both readers negative for stale ids" — pinning it
        // prevents a future SPI shim that defaults bounds to .zero from
        // silently breaking the guard.
        try expectEqual(Overlay.isOrderedIn(0), false)
        try expect(Overlay.bounds(of: 0) == nil)
    }

    // MARK: - RegionOverlayGeometry — free-region overlay placement (pure)

    test("RegionOverlayGeometry.sanitize rejects degenerate rects") {
        // Zero / negative / non-finite sizes would make an invisible panel or
        // trip an AppKit assertion — gate them before NSPanel.setFrame.
        try expect(RegionOverlayGeometry.sanitize(CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
        try expect(RegionOverlayGeometry.sanitize(CGRect(x: 0, y: 0, width: 10, height: 0)) == nil)
        try expect(RegionOverlayGeometry.sanitize(CGRect(x: 0, y: 0, width: -5, height: 10)) == nil)
        try expect(RegionOverlayGeometry.sanitize(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == nil)
        try expect(RegionOverlayGeometry.sanitize(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)) == nil)
    }

    test("RegionOverlayGeometry.sanitize passes a normal rect through") {
        let r = CGRect(x: 12, y: 34, width: 200, height: 100)
        try expect(RegionOverlayGeometry.sanitize(r) == r)
    }

    test("RegionOverlayGeometry.toAppKit preserves x/w/h and flips y") {
        // Global (top-left) → AppKit (bottom-left): only y changes; x, w, h
        // are invariant. The flip is what lands the panel on the right
        // display, so pin the relationship rather than a hardcoded number.
        let g = CGRect(x: 100, y: 50, width: 300, height: 80)
        let a = RegionOverlayGeometry.toAppKit(g)
        try expectEqual(a.origin.x, g.origin.x)
        try expectEqual(a.size.width, g.size.width)
        try expectEqual(a.size.height, g.size.height)
        if let primary = NSScreen.screens.first {
            try expectEqual(a.origin.y, primary.frame.maxY - g.maxY)
        } else {
            // Headless fallback (no screens): identity, per cgsToAppKit's guard.
            try expectEqual(a.origin.y, g.origin.y)
        }
    }

    test("RegionOverlayHandle.remove then setFrame is a safe no-op") {
        // Teardown race: a gesture step can land after the bracket closed and
        // remove() ran. The released guard must swallow setFrame rather than
        // touch a closed panel. Degenerate panel, no orderFront → nothing
        // visible during the suite (same constraint as the OverlayHandle tests).
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = RegionOverlayHandle(id: 1, panel: panel, webView: webView)
        h.remove()
        h.setFrame(CGRect(x: 0, y: 0, width: 100, height: 100))  // must not crash
        try expectEqual(h.panel.isVisible, false)
    }
}
