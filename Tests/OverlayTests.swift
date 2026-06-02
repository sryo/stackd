import Foundation
import AppKit
import CoreGraphics

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
}
