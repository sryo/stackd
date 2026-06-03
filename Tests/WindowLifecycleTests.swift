import AppKit
import Foundation

/// Tests for `FirstPaintGate` — the state machine that holds StackWindow
/// hidden (alphaValue=0) between `orderFront` and WKWebView's first paint.
///
/// We test the gate in isolation rather than driving a real WKWebView:
/// the gate is pure (no AppKit / WebKit state), and the StackWindow code
/// around it (alphaValue toggling, Timer scheduling, NSWindow.orderFront
/// overrides) is impure macOS-state plumbing that the harness can't drive
/// without a running NSApplication + WKWebView event loop.
///
/// What the gate guarantees:
///   1. Show is armed exactly once (first orderFront wins; subsequent shows
///      are no-ops so re-ordering a revealed window doesn't re-hide it).
///   2. Reveal happens exactly once (whichever signal lands first — finish,
///      fail, or fallback — wins; the rest become no-ops).
///   3. Reveal signals before a show is armed are dropped (defensive — a
///      WKWebView could in principle finish loading before anyone called
///      orderFront; revealing nothing is fine).
func registerWindowLifecycleTests() {

    // MARK: arming

    test("FirstPaintGate: starts idle") {
        let g = FirstPaintGate()
        try expect(g.state == .idle)
    }

    test("FirstPaintGate: first show arms the gate, returns true") {
        var g = FirstPaintGate()
        try expect(g.shouldArmOnShow() == true)
        try expect(g.state == .armed)
    }

    test("FirstPaintGate: second show is a no-op (returns false, stays armed)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.shouldArmOnShow() == false)
        try expect(g.state == .armed)
    }

    test("FirstPaintGate: re-arm after reveal is a no-op (don't re-hide a visible window)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFinish()
        try expect(g.state == .revealed)
        try expect(g.shouldArmOnShow() == false)
        try expect(g.state == .revealed)
    }

    // MARK: reveal on first paint

    test("FirstPaintGate: didFinish after show reveals, returns true") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.shouldRevealOnLoadFinish() == true)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: second didFinish is a no-op (within-window reloads don't re-reveal)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFinish()
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: didFinish without arming is dropped (defensive)") {
        var g = FirstPaintGate()
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.state == .idle)
    }

    // MARK: reveal on failure

    test("FirstPaintGate: didFail after show reveals (broken stacks aren't invisible)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.shouldRevealOnLoadFail() == true)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: didFail after didFinish is a no-op") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFinish()
        try expect(g.shouldRevealOnLoadFail() == false)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: didFinish after didFail is a no-op (failure already revealed)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFail()
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.state == .revealed)
    }

    // MARK: fallback timer

    test("FirstPaintGate: fallback fires after show, returns true") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.fallbackFired() == true)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: fallback after didFinish is a no-op (already revealed)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFinish()
        try expect(g.fallbackFired() == false)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: fallback without arming is dropped") {
        var g = FirstPaintGate()
        try expect(g.fallbackFired() == false)
        try expect(g.state == .idle)
    }

    // MARK: fallback duration

    test("StackWindow.firstPaintFallback is a positive safety net (not timing-based correctness)") {
        // Documented as 2s in StackWindow. If this changes, the comment in
        // StackWindow.swift explaining "NOT timing-based correctness" should
        // be revisited.
        try expect(StackWindow.firstPaintFallback > 0)
        try expect(StackWindow.firstPaintFallback >= 1.0)
        try expect(StackWindow.firstPaintFallback <= 5.0)
    }

    // MARK: full lifecycle scenario

    test("FirstPaintGate: typical happy-path lifecycle (idle → armed → revealed)") {
        var g = FirstPaintGate()
        try expect(g.state == .idle)
        try expect(g.shouldArmOnShow() == true)
        try expect(g.state == .armed)
        try expect(g.shouldRevealOnLoadFinish() == true)
        try expect(g.state == .revealed)
        // Subsequent signals (reload, re-show, fallback) all no-op:
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.shouldArmOnShow() == false)
        try expect(g.fallbackFired() == false)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: broken-stack lifecycle (didFail before didFinish reveals anyway)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.shouldRevealOnLoadFail() == true)
        // didFinish would never arrive for a 404'd provisional nav, but if
        // it did, we'd no-op (already revealed):
        try expect(g.shouldRevealOnLoadFinish() == false)
    }

    test("FirstPaintGate: no-content lifecycle (fallback rescues a never-loaded window)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        // Nothing loaded — eventually the timer fires:
        try expect(g.fallbackFired() == true)
        // A late navigation finish doesn't undo or re-fire:
        try expect(g.shouldRevealOnLoadFinish() == false)
    }

    // MARK: gate override (JS-controlled alpha via sd.window.setAlpha)

    test("FirstPaintGate: override before reveal disables auto-reveal on didFinish") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        g.markOverridden()
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.state == .armed) // state unchanged; JS owns alpha now
    }

    test("FirstPaintGate: override disables fallback reveal") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        g.markOverridden()
        try expect(g.fallbackFired() == false)
    }

    test("FirstPaintGate: override disables didFail reveal") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        g.markOverridden()
        try expect(g.shouldRevealOnLoadFail() == false)
    }

    test("FirstPaintGate: override blocks re-arming on subsequent show") {
        // A revealed-then-hidden stack stays under JS control — re-show
        // doesn't reactivate the gate.
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        g.markOverridden()
        // Even from idle, the override sticks (defensive — if JS calls
        // setAlpha early, before orderFront, the gate must respect it).
        var g2 = FirstPaintGate()
        g2.markOverridden()
        try expect(g2.shouldArmOnShow() == false)
        try expect(g2.state == .idle)
    }

    // MARK: setAlpha body parsing

    test("setAlpha: missing value → nil (reject, don't clamp to 0)") {
        try expect(StackWindow.parseSetAlpha([:]) == nil)
    }
    test("setAlpha: non-numeric value → nil") {
        try expect(StackWindow.parseSetAlpha(["value": "0.5"]) == nil)
    }
    test("setAlpha: NaN → nil") {
        try expect(StackWindow.parseSetAlpha(["value": Double.nan]) == nil)
    }
    test("setAlpha: +infinity → nil") {
        try expect(StackWindow.parseSetAlpha(["value": Double.infinity]) == nil)
    }
    test("setAlpha: valid mid-range passes through") {
        try expectEqual(StackWindow.parseSetAlpha(["value": 0.5]), 0.5)
    }
    test("setAlpha: 0 passes through") {
        try expectEqual(StackWindow.parseSetAlpha(["value": 0.0]), 0.0)
    }
    test("setAlpha: 1 passes through") {
        try expectEqual(StackWindow.parseSetAlpha(["value": 1.0]), 1.0)
    }
    test("setAlpha: negative clamps to 0") {
        try expectEqual(StackWindow.parseSetAlpha(["value": -0.5]), 0.0)
    }
    test("setAlpha: above 1 clamps to 1") {
        try expectEqual(StackWindow.parseSetAlpha(["value": 1.7]), 1.0)
    }
}
