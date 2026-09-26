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

    test("OverlayRepinPolicy reorders on frame change regardless of elapsed time") {
        // Frame changed = the target moved/resized/retargeted. The reorder
        // must ride along every time — this is the event-driven primary.
        try expectEqual(OverlayRepinPolicy.shouldReorder(frameChanged: true, sinceReorder: 0), true)
        try expectEqual(OverlayRepinPolicy.shouldReorder(frameChanged: true, sinceReorder: 0.01), true)
    }

    test("OverlayRepinPolicy holds off below the cadence when the frame is static") {
        // Static frame + recent reorder → skip the WindowServer round-trip.
        try expectEqual(
            OverlayRepinPolicy.shouldReorder(
                frameChanged: false,
                sinceReorder: OverlayRepinPolicy.reorderCadence - 0.01),
            false)
        try expectEqual(OverlayRepinPolicy.shouldReorder(frameChanged: false, sinceReorder: 0), false)
    }

    test("OverlayRepinPolicy fires the safety reorder at the cadence ceiling") {
        // Clicking an already-focused window raises it above the panel
        // WITHOUT changing its frame, so the frame-diff alone never reorders.
        // CGS 808 → forceRepin is the event-driven path; this cadence is the
        // ceiling if 808 goes quiet. Measured in seconds, not ticks: ticks
        // only run while armed or on the backstop.
        try expectEqual(
            OverlayRepinPolicy.shouldReorder(
                frameChanged: false,
                sinceReorder: OverlayRepinPolicy.reorderCadence),
            true)
        try expect(OverlayRepinPolicy.reorderCadence >= OverlayTickArm.backstopInterval,
                   "a cadence below the backstop would reorder on every backstop tick")
        try expect(OverlayRepinPolicy.reorderCadence <= 2,
                   "a cadence this high leaves a wrong z-order visible for seconds")
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

    test("RegionOverlayHandle.setFrame with the same size lands the new origin") {
        // A deferred panel has no window-server window yet, so the move takes
        // the AppKit fallback and panel.frame reflects it straight away.
        let start = CGRect(x: 100, y: 100, width: 80, height: 40)
        let panel = NSPanel(contentRect: RegionOverlayGeometry.toAppKit(start), styleMask: .borderless,
                            backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = RegionOverlayHandle(id: 1, panel: panel, webView: webView)
        let moved = start.offsetBy(dx: 30, dy: 12)
        h.setFrame(moved)
        h.syncAppKitFrame()
        try expect(h.panel.frame == RegionOverlayGeometry.toAppKit(moved))
        h.remove()
    }

    test("RegionOverlayHandle.setFrame with a new size reshapes the panel") {
        let start = CGRect(x: 100, y: 100, width: 80, height: 40)
        let panel = NSPanel(contentRect: RegionOverlayGeometry.toAppKit(start), styleMask: .borderless,
                            backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = RegionOverlayHandle(id: 1, panel: panel, webView: webView)
        let grown = CGRect(x: 90, y: 100, width: 120, height: 60)
        h.setFrame(grown)
        try expect(h.panel.frame == RegionOverlayGeometry.toAppKit(grown))
        h.remove()
    }

    test("Overlay.makeOverlayPanel orders out without an animation") {
        // Stack reloads (e.g. on a display change) block the main thread
        // while every stack rebuilds; an animated order-out can't run until
        // that finishes, leaving the old outline frozen on screen.
        let panel = Overlay.makeOverlayPanel(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                                             attachedToWindow: true)
        try expect(panel.animationBehavior == .none)
        try expect(panel.ignoresMouseEvents)
        try expect(!panel.canBecomeKey)
        panel.close()
    }

    test("Overlay.makeOverlayPanel: a window-attached panel is transient, not stationary") {
        // Transient panels step aside with Show Desktop / Mission Control
        // the way their target window does; stationary ones stay pinned
        // in place over an empty desktop.
        let panel = Overlay.makeOverlayPanel(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                                             attachedToWindow: true)
        let b = panel.collectionBehavior
        try expect(b.contains(.transient))
        try expect(!b.contains(.stationary))
        try expect(b.contains(.canJoinAllSpaces))
        try expect(b.contains(.fullScreenAuxiliary))
        try expect(b.contains(.ignoresCycle))
        panel.close()
    }

    test("Overlay.makeOverlayPanel hides both panel kinds from the screencapture window picker") {
        // The Cmd-Shift-4/5 window picker would otherwise offer the
        // always-on-top overlay instead of the window beneath it.
        for attached in [true, false] {
            let panel = Overlay.makeOverlayPanel(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                                                 attachedToWindow: attached)
            let wid = CGWindowID(panel.windowNumber)
            try expect(wid != 0, "panel has no window-server window")
            try expectEqual(WindowServerProperty.bool(WindowServerProperty.ignoreForScreencaptureSelection,
                                                      of: wid), true)
            panel.close()
        }
    }

    test("a plain panel is not hidden from the screencapture window picker") {
        let panel = NSPanel(contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let wid = CGWindowID(panel.windowNumber)
        try expect(WindowServerProperty.bool(WindowServerProperty.ignoreForScreencaptureSelection,
                                             of: wid) != true)
        panel.close()
    }

    test("WindowServerProperty.setBool refuses kCGNullWindowID") {
        try expectEqual(WindowServerProperty.setBool(WindowServerProperty.ignoreForScreencaptureSelection,
                                                     true, on: 0), false)
        try expectEqual(WindowServerProperty.bool(WindowServerProperty.ignoreForScreencaptureSelection,
                                                  of: 0), nil)
    }

    test("Overlay.makeOverlayPanel: a free region panel stays stationary like a HUD stack") {
        let panel = Overlay.makeOverlayPanel(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                                             attachedToWindow: false)
        let b = panel.collectionBehavior
        try expect(b.contains(.stationary))
        try expect(!b.contains(.transient))
        try expect(b.contains(.canJoinAllSpaces))
        try expect(b.contains(.fullScreenAuxiliary))
        try expect(b.contains(.ignoresCycle))
        panel.close()
    }

    // MARK: - OverlayTargetLevel — an attached panel shares its target's level (pure)

    test("OverlayTargetLevel reads the level of a new target") {
        var cache = OverlayTargetLevel()
        var reads: [CGWindowID] = []
        let level = cache.resolve(target: 42, refresh: false) { wid in reads.append(wid); return 3 }
        try expectEqual(level, 3)
        try expectEqual(reads, [42])
    }

    test("OverlayTargetLevel serves the cached level for the same target without a read") {
        var cache = OverlayTargetLevel()
        _ = cache.resolve(target: 42, refresh: false) { _ in 3 }
        var reads = 0
        let level = cache.resolve(target: 42, refresh: false) { _ in reads += 1; return 8 }
        try expectEqual(level, 3)
        try expectEqual(reads, 0, "a static target must not cost a window-server read per tick")
    }

    test("OverlayTargetLevel re-reads on retarget and on an explicit refresh") {
        var cache = OverlayTargetLevel()
        _ = cache.resolve(target: 42, refresh: false) { _ in 0 }
        try expectEqual(cache.resolve(target: 43, refresh: false) { _ in 3 }, 3)
        try expectEqual(cache.resolve(target: 43, refresh: true) { _ in 8 }, 8,
                        "a repin must pick up a target that changed level in place")
    }

    test("OverlayTargetLevel keeps the known level when a refresh read fails") {
        var cache = OverlayTargetLevel()
        _ = cache.resolve(target: 42, refresh: false) { _ in 3 }
        try expectEqual(cache.resolve(target: 42, refresh: true) { _ in nil }, 3)
    }

    test("OverlayTargetLevel falls back to the normal level when a new target can't be read") {
        // Never the statusBar level: that sits above the Dock. The failed
        // read is retried on the next resolve instead of being cached.
        var cache = OverlayTargetLevel()
        _ = cache.resolve(target: 42, refresh: false) { _ in 3 }
        let level = cache.resolve(target: 43, refresh: false) { _ in nil }
        try expectEqual(level, OverlayTargetLevel.fallback)
        try expectEqual(OverlayTargetLevel.fallback, NSWindow.Level.normal.rawValue)
        var retried = false
        try expectEqual(cache.resolve(target: 43, refresh: false) { _ in retried = true; return 3 }, 3)
        try expect(retried, "an unread target must be read again, not served the fallback forever")
    }

    test("OverlayTargetLevel.panelLevel puts a normal window's border in the band under the Dock") {
        // Never the target's own level: inside a shared level a raise of the
        // target can land after the panel's reorder and cover the border.
        let level = OverlayTargetLevel.panelLevel(above: NSWindow.Level.normal.rawValue)
        try expectEqual(level, NSWindow.Level.dock.rawValue - 1)
        try expect(level > NSWindow.Level.modalPanel.rawValue,
                   "above every level an app window normally sits at")
        try expectEqual(OverlayTargetLevel.panelLevel(above: NSWindow.Level.floating.rawValue), level)
    }

    test("OverlayTargetLevel.panelLevel stays above a target already at or over that band") {
        let band = NSWindow.Level.dock.rawValue - 1
        try expectEqual(OverlayTargetLevel.panelLevel(above: band), band + 1)
        try expectEqual(OverlayTargetLevel.panelLevel(above: NSWindow.Level.statusBar.rawValue),
                        NSWindow.Level.statusBar.rawValue + 1)
    }

    test("Overlay.makeOverlayPanel: a window-attached panel starts above normal windows, below the Dock") {
        let panel = Overlay.makeOverlayPanel(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                                             attachedToWindow: true)
        try expectEqual(panel.level.rawValue, OverlayTargetLevel.panelLevel(above: NSWindow.Level.normal.rawValue))
        try expect(panel.level > .normal)
        try expect(panel.level < .dock)
        panel.close()
    }

    test("Overlay.makeOverlayPanel: a free region panel keeps the statusBar level") {
        let panel = Overlay.makeOverlayPanel(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                                             attachedToWindow: false)
        try expectEqual(panel.level, .statusBar)
        panel.close()
    }

    test("Overlay reads window state on its own connection, not the one that owns the panels") {
        // The reads would otherwise first wait for the window server to apply
        // every panel transaction the main connection committed.
        try expect(Overlay.readConnection != 0)
        try expect(Overlay.readConnection != SkyLight.cid)
    }

    test("OverlayWindowQuery: the visible attribute bit is what SLSWindowIsOrderedIn reports") {
        // Attributes read for one window across shown / minimized / hidden /
        // ordered out: 0x3 while ordered in, 0x1 otherwise.
        try expect(OverlayWindowQuery.isOrderedIn(attributes: 0x3))
        try expect(!OverlayWindowQuery.isOrderedIn(attributes: 0x1))
        try expect(!OverlayWindowQuery.isOrderedIn(attributes: 0))
    }

    test("Overlay.isOrderedIn is false for no window and for one never ordered in") {
        try expect(!Overlay.isOrderedIn(0))
        let panel = NSPanel(contentRect: NSRect(x: -9999, y: -9999, width: 12, height: 10),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let wid = CGWindowID(panel.windowNumber)
        try expect(wid != 0, "panel has no window-server window")
        try expect(!Overlay.isOrderedIn(wid))
        panel.close()
    }

    test("Overlay.bounds(of:) reads a live window from the read connection") {
        let panel = NSPanel(contentRect: NSRect(x: -9999, y: -9999, width: 12, height: 10),
                            styleMask: .borderless, backing: .buffered, defer: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        CATransaction.flush()
        let wid = CGWindowID(panel.windowNumber)
        try expect(wid != 0, "panel has no window-server window")
        try expectEqual(Overlay.bounds(of: wid)?.size, CGSize(width: 12, height: 10))
        panel.orderOut(nil)
        panel.close()
    }

    test("Overlay.level(of:) returns nil for kCGNullWindowID") {
        try expect(Overlay.level(of: 0) == nil)
    }

    test("Overlay.level(of:) reads a live window's level") {
        let panel = NSPanel(contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                            styleMask: .borderless, backing: .buffered, defer: false)
        // AppKit hands the level to the window server on the next
        // CATransaction commit of an ordered-in window; a fully transparent
        // 1pt panel far off screen is ordered in without showing anything.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.level = .floating
        CATransaction.flush()
        let wid = CGWindowID(panel.windowNumber)
        try expect(wid != 0, "panel has no window-server window")
        try expectEqual(Overlay.level(of: wid), NSWindow.Level.floating.rawValue)
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - OverlayTrace (pure)

    test("OverlayTrace.report is silent for an observation under the stall threshold") {
        try expect(OverlayTrace.report(start: 10, end: 10.02, ops: [(t: 9.99, op: "reshape")]) == nil)
    }

    test("OverlayTrace.report names the writes before a blocked observation") {
        let line = OverlayTrace.report(start: 10, end: 10.49,
                                       ops: [(t: 9.984, op: "commanded"), (t: 9.985, op: "reshape")])
        try expectEqual(line, "overlay: tick blocked 490ms; before: commanded@-16 reshape@-15")
    }
}
