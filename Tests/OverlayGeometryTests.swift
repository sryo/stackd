import Foundation
import AppKit
import CoreGraphics
import WebKit

// Tests for the Round-2 interaction-primitive geometry in
// `Sources/DataSources/Overlay.swift`:
//
//   1. `OverlayGeometry` — panel placement + per-tick sd.target payload for
//      the `outset` option on overlay.attach. Outset 0 must be byte-level
//      back-compatible with the pre-outset tick (exact pin, {x:0,y:0,w,h}
//      payload) modulo the additive `outset` field.
//
//   2. `RegionFollowGeometry` — where the region panel goes while the daemon
//      follows the cursor (overlay.region.follow). origin = cursor + offset,
//      size untouched.
//
//   3. `OverlayHandle.setOutset` — the mutation the overlay.setOutset RPC
//      lands on: repin request, retarget preservation, released-guard no-op.
//      Degenerate NSPanel + WKWebView pairs, never orderFront'ed — nothing
//      visible during the suite (same constraint as OverlayTests.swift).

func registerOverlayGeometryTests() {
    // MARK: - OverlayGeometry.panelFrame

    test("OverlayGeometry.panelFrame with zero outset is the identity") {
        // Outset 0 = today's exact-pin behavior. Any drift here breaks every
        // existing overlay stack that never heard of outset.
        let target = CGRect(x: 100, y: 50, width: 400, height: 300)
        try expect(OverlayGeometry.panelFrame(target: target, outset: 0) == target)
    }

    test("OverlayGeometry.panelFrame grows all four sides by the outset") {
        // insetBy(dx:-N, dy:-N): origin shifts up-left by N, size grows by 2N
        // in each dimension — the outset band is N points on EVERY side.
        let target = CGRect(x: 100, y: 50, width: 400, height: 300)
        let panel = OverlayGeometry.panelFrame(target: target, outset: 8)
        try expectEqual(panel.origin.x, 92)
        try expectEqual(panel.origin.y, 42)
        try expectEqual(panel.width, 416)
        try expectEqual(panel.height, 316)
        // Both edges symmetric: target centered in the panel.
        try expectEqual(panel.maxX - target.maxX, 8)
        try expectEqual(panel.maxY - target.maxY, 8)
    }

    // MARK: - OverlayGeometry.sanitizeOutset

    test("OverlayGeometry.sanitizeOutset zeroes negative and non-finite input") {
        // JS can send anything over the bridge. A negative outset shrinks the
        // panel INSIDE the target and past half the target size produces a
        // negative-size NSPanel frame; NaN/inf poison every downstream rect.
        try expectEqual(OverlayGeometry.sanitizeOutset(-8), 0)
        try expectEqual(OverlayGeometry.sanitizeOutset(.nan), 0)
        try expectEqual(OverlayGeometry.sanitizeOutset(.infinity), 0)
        try expectEqual(OverlayGeometry.sanitizeOutset(0), 0)
        try expectEqual(OverlayGeometry.sanitizeOutset(8), 8)
    }

    // MARK: - OverlayGeometry.targetPayloadJS

    test("OverlayGeometry.targetPayloadJS places the target at (outset, outset)") {
        // Panel coordinates: with the panel grown by N on every side, the
        // target's top-left sits at (N, N) inside it. Spec authors position
        // off these fields, so the payload — not just the panel frame — must
        // carry the shift.
        let target = CGRect(x: 100, y: 50, width: 400, height: 300)
        let js = OverlayGeometry.targetPayloadJS(targetFrame: target, outset: 8)
        try expect(js.contains("window.sd.target={x:8,y:8,w:400,h:300,outset:8}"),
                   "expected target-in-panel coords in: \(js)")
    }

    test("OverlayGeometry.targetPayloadJS with outset 0 matches the legacy payload plus outset") {
        // Back-compat pin: existing overlay stacks read {x:0,y:0,w,h}; the
        // only additive change at outset 0 is the new outset field.
        let target = CGRect(x: 0, y: 0, width: 640, height: 480)
        let js = OverlayGeometry.targetPayloadJS(targetFrame: target, outset: 0)
        try expect(js.contains("window.sd.target={x:0,y:0,w:640,h:480,outset:0}"),
                   "expected legacy-shaped payload in: \(js)")
        try expect(js.contains("window.dispatchEvent(new CustomEvent('sd:target'"),
                   "payload must still dispatch the sd:target event")
    }

    // MARK: - RegionFollowGeometry.frame

    test("RegionFollowGeometry.frame origin is cursor plus offset, size preserved") {
        // The offset is the grab point a drag ghost captures at drag start
        // (cursor-to-corner delta) so the panel doesn't snap its top-left
        // under the cursor mid-drag.
        let f = RegionFollowGeometry.frame(
            cursor: CGPoint(x: 500, y: 300),
            offset: CGPoint(x: -40, y: -12),
            size: CGSize(width: 320, height: 200))
        try expectEqual(f.origin.x, 460)
        try expectEqual(f.origin.y, 288)
        try expectEqual(f.width, 320)
        try expectEqual(f.height, 200)
    }

    test("RegionFollowGeometry.frame with zero offset pins the origin to the cursor") {
        let f = RegionFollowGeometry.frame(
            cursor: CGPoint(x: 123, y: 456),
            offset: .zero,
            size: CGSize(width: 10, height: 10))
        try expectEqual(f.origin, CGPoint(x: 123, y: 456))
    }

    // MARK: - OverlayHandle.setOutset — the RPC's landing point

    test("OverlayHandle.setOutset requests a repin and setTarget preserves the outset") {
        // setOutset changes the (target, outset) → panel-frame derivation
        // without the target moving, so the tick's frame-diff short-circuit
        // would otherwise never reposition. Retarget must NOT reset the
        // outset — overlay-border keeps one panel across focus changes.
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 10, targetWID: 100, panel: panel, webView: webView)
        try expectEqual(h.outset, 0, "fresh handle defaults to exact pin")
        h.setOutset(8)
        try expectEqual(h.outset, 8)
        try expectEqual(h.repinRequested, true, "setOutset must request a repin")
        h.setTarget(200)
        try expectEqual(h.outset, 8, "retarget must preserve the outset")
        h.detach()
    }

    test("OverlayHandle.setOutset sanitizes garbage and no-ops when unchanged") {
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 11, targetWID: 100, panel: panel, webView: webView)
        h.setOutset(-5)
        try expectEqual(h.outset, 0, "negative outset must sanitize to 0")
        try expectEqual(h.repinRequested, false,
                        "unchanged outset (0 → sanitized 0) must not dirty the frame cache")
        h.detach()
    }

    test("OverlayHandle.setOutset on a detached handle is a safe no-op") {
        // Same teardown race as setTarget/forceRepin: an RPC can land while
        // a stack reload drains handles.
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 12, targetWID: 100, panel: panel, webView: webView)
        h.detach()
        h.setOutset(8)
        try expectEqual(h.outset, 0, "detached handle must not accept outset changes")
    }

    test("OverlayHandle attach-time outset is sanitized at init") {
        let panel   = NSPanel(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let h = OverlayHandle(id: 13, targetWID: 100, panel: panel,
                              webView: webView, outset: -3)
        try expectEqual(h.outset, 0)
        h.detach()
    }
}
