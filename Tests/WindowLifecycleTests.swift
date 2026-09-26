import AppKit
import Foundation

/// Tests for `FirstPaintGate` — the state machine that holds StackWindow
/// hidden (alphaValue=0) between `orderFront` and WKWebView's first paint —
/// and for StackWindow's sd.window.setAlpha / setFrame / setClickThrough
/// body parsers.
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

    // MARK: single transitions

    test("FirstPaintGate: second show is a no-op (returns false, stays armed)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.shouldArmOnShow() == false)
        try expect(g.state == .armed)
    }

    test("FirstPaintGate: reveal signals before arming are dropped") {
        var g = FirstPaintGate()
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.shouldRevealOnLoadFail() == false)
        try expect(g.fallbackFired() == false)
        try expect(g.state == .idle)
    }

    test("FirstPaintGate: didFail after didFinish is a no-op") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFinish()
        try expect(g.shouldRevealOnLoadFail() == false)
        try expect(g.state == .revealed)
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
        try expect(g.state == .revealed)
        // didFinish would never arrive for a 404'd provisional nav, but if
        // it did, we'd no-op (already revealed):
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.state == .revealed)
    }

    test("FirstPaintGate: no-content lifecycle (fallback rescues a never-loaded window)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        // Nothing loaded — eventually the timer fires:
        try expect(g.fallbackFired() == true)
        try expect(g.state == .revealed)
        // A late navigation finish doesn't undo or re-fire:
        try expect(g.shouldRevealOnLoadFinish() == false)
        try expect(g.fallbackFired() == false)
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

    test("FirstPaintGate: override before the first show blocks arming") {
        // JS may call setAlpha before orderFront; the gate must then never
        // hide the window.
        var g = FirstPaintGate()
        g.markOverridden()
        try expect(g.shouldArmOnShow() == false)
        try expect(g.state == .idle)
    }

    // MARK: setAlpha body parsing

    test("setAlpha: missing value → nil (reject, don't clamp to 0)") {
        try expect(StackWindow.parseSetAlpha([:]) == nil)
    }
    test("setAlpha: non-numeric value → nil") {
        try expect(StackWindow.parseSetAlpha(["value": "0.5"]) == nil)
    }
    test("setAlpha: non-finite value → nil") {
        try expect(StackWindow.parseSetAlpha(["value": Double.nan]) == nil)
        try expect(StackWindow.parseSetAlpha(["value": Double.infinity]) == nil)
    }
    test("setAlpha: values in [0, 1] pass through, bounds included") {
        try expectEqual(StackWindow.parseSetAlpha(["value": 0.0]), 0.0)
        try expectEqual(StackWindow.parseSetAlpha(["value": 0.5]), 0.5)
        try expectEqual(StackWindow.parseSetAlpha(["value": 1.0]), 1.0)
    }
    test("setAlpha: negative clamps to 0") {
        try expectEqual(StackWindow.parseSetAlpha(["value": -0.5]), 0.0)
    }
    test("setAlpha: above 1 clamps to 1") {
        try expectEqual(StackWindow.parseSetAlpha(["value": 1.7]), 1.0)
    }

    // MARK: setFrame body parsing
    //
    // CG / AX convention (top-left origin) — same as sd.windows.focused and
    // AXFrame. x/y required and finite. w/h optional; must be positive +
    // finite when present, treated as missing otherwise.

    test("setFrame: missing x → nil") {
        try expect(StackWindow.parseSetFrame(["y": 100.0]) == nil)
    }
    test("setFrame: missing y → nil") {
        try expect(StackWindow.parseSetFrame(["x": 100.0]) == nil)
    }
    test("setFrame: non-numeric x → nil") {
        try expect(StackWindow.parseSetFrame(["x": "100", "y": 100.0]) == nil)
    }
    test("setFrame: NaN y → nil") {
        try expect(StackWindow.parseSetFrame(["x": 100.0, "y": Double.nan]) == nil)
    }
    test("setFrame: x/y only → w/h are nil (preserve current dimensions)") {
        let p = StackWindow.parseSetFrame(["x": 100.0, "y": 200.0])
        try expect(p != nil)
        try expectEqual(p?.x, 100.0)
        try expectEqual(p?.y, 200.0)
        try expect(p?.w == nil)
        try expect(p?.h == nil)
    }
    test("setFrame: full x/y/w/h passes through") {
        let p = StackWindow.parseSetFrame(["x": 100.0, "y": 200.0, "w": 320.0, "h": 320.0])
        try expectEqual(p?.x, 100.0)
        try expectEqual(p?.y, 200.0)
        try expectEqual(p?.w, 320.0)
        try expectEqual(p?.h, 320.0)
    }
    test("setFrame: zero w treated as missing") {
        let p = StackWindow.parseSetFrame(["x": 100.0, "y": 200.0, "w": 0.0, "h": 320.0])
        try expect(p?.w == nil)
        try expectEqual(p?.h, 320.0)
    }
    test("setFrame: negative h treated as missing") {
        let p = StackWindow.parseSetFrame(["x": 100.0, "y": 200.0, "w": 320.0, "h": -5.0])
        try expectEqual(p?.w, 320.0)
        try expect(p?.h == nil)
    }
    test("setFrame: infinite w treated as missing") {
        let p = StackWindow.parseSetFrame(["x": 100.0, "y": 200.0, "w": Double.infinity, "h": 320.0])
        try expect(p?.w == nil)
    }

    // MARK: setClickThrough body parsing
    //
    // Bool-only value field. Anything else (missing, string, number) returns
    // nil and the bridge responds false rather than silently coercing — same
    // strict shape as setAlpha / setFrame.

    test("setClickThrough: true passes through") {
        try expectEqual(StackWindow.parseSetClickThrough(["value": true]), true)
    }
    test("setClickThrough: false passes through") {
        try expectEqual(StackWindow.parseSetClickThrough(["value": false]), false)
    }
    test("setClickThrough: missing value → nil") {
        try expect(StackWindow.parseSetClickThrough([:]) == nil)
    }
    test("setClickThrough: numeric value → nil (no truthy coercion)") {
        // Bridge bodies arrive as NSNumber, not Swift Int.
        try expect(StackWindow.parseSetClickThrough(["value": NSNumber(value: 2)]) == nil)
        try expect(StackWindow.parseSetClickThrough(["value": NSNumber(value: 0.5)]) == nil)
    }
    test("setClickThrough: string value → nil") {
        try expect(StackWindow.parseSetClickThrough(["value": "true"]) == nil)
    }

    // MARK: revealedDirectly (invocable-stack first-invoke shortcut)
    //
    // Invocable stacks load their page BEFORE first orderFront. The gate's
    // normal arm-then-wait-for-didFinish path stalls on the 2s fallback
    // (no didFinish coming for an already-loaded page). revealedDirectly()
    // is the bypass: idle → revealed in one hop, no alpha jiggle.

    test("FirstPaintGate: revealedDirectly from idle transitions to revealed") {
        var g = FirstPaintGate()
        try expect(g.revealedDirectly() == true)
        try expect(g.state == .revealed)
    }
    test("FirstPaintGate: revealedDirectly from armed is a no-op (already arming the normal flow)") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        try expect(g.revealedDirectly() == false)
        try expect(g.state == .armed)
    }
    test("FirstPaintGate: revealedDirectly from revealed is a no-op") {
        var g = FirstPaintGate()
        _ = g.shouldArmOnShow()
        _ = g.shouldRevealOnLoadFinish()
        try expect(g.revealedDirectly() == false)
        try expect(g.state == .revealed)
    }
    test("FirstPaintGate: revealedDirectly respects override (JS owns alpha)") {
        var g = FirstPaintGate()
        g.markOverridden()
        try expect(g.revealedDirectly() == false)
        try expect(g.state == .idle)
    }
    test("FirstPaintGate: revealedDirectly + later didFinish — only first transition wins") {
        // Invocable stack flow: page loads (gate idle, didFinish no-ops),
        // then orderFront triggers armFirstPaintGate which sees the loaded
        // flag and calls revealedDirectly. A subsequent didFinish (e.g.
        // JS-driven reload) is a no-op.
        var g = FirstPaintGate()
        _ = g.revealedDirectly()
        try expect(g.shouldRevealOnLoadFinish() == false)
    }
}
