import Foundation
import CoreGraphics

// Tests for `OverlayTickPlan` in `Sources/DataSources/Overlay.swift` — the
// pure per-tick decision of what an overlay must do given the target's
// current geometry: nothing, a cheap origin-only move, or a full reshape
// (which WebKit has to lay out), and whether the `sd.target` payload needs
// re-pushing into the WebView.

func registerOverlayTickPlanTests() {
    let base = CGRect(x: 100, y: 200, width: 400, height: 300)

    test("OverlayTickPlan.frameOp is none when the frame is unchanged") {
        try expect(OverlayTickPlan.frameOp(next: base, last: base) == .none)
    }

    test("OverlayTickPlan.frameOp absorbs sub-half-point jitter") {
        let jittered = base.offsetBy(dx: 0.3, dy: -0.4)
        try expect(OverlayTickPlan.frameOp(next: jittered, last: base) == .none)
    }

    test("OverlayTickPlan.frameOp is a move when only the origin changes") {
        let moved = base.offsetBy(dx: 40, dy: -12)
        try expect(OverlayTickPlan.frameOp(next: moved, last: base) == .move(moved.origin))
    }

    test("OverlayTickPlan.frameOp is a reshape when the size changes") {
        let resized = CGRect(x: 100, y: 200, width: 420, height: 300)
        try expect(OverlayTickPlan.frameOp(next: resized, last: base) == .reshape(resized))
    }

    test("OverlayTickPlan.frameOp is a reshape from the zero sentinel (first tick / repin)") {
        try expect(OverlayTickPlan.frameOp(next: base, last: .zero) == .reshape(base))
    }

    test("OverlayTickPlan.payloadToPush returns nil when the payload is unchanged") {
        let js = OverlayGeometry.targetPayloadJS(targetFrame: base, outset: 0)
        try expect(OverlayTickPlan.payloadToPush(js, lastPushed: js) == nil)
    }

    test("OverlayTickPlan.payloadToPush: a pure move leaves the payload unchanged") {
        // Payload is in PANEL coordinates, so dragging the target never
        // changes it — the per-vsync push during a drag was pure waste.
        let a = OverlayGeometry.targetPayloadJS(targetFrame: base, outset: 4)
        let b = OverlayGeometry.targetPayloadJS(targetFrame: base.offsetBy(dx: 80, dy: 30), outset: 4)
        try expect(OverlayTickPlan.payloadToPush(b, lastPushed: a) == nil)
    }

    test("OverlayTickPlan.payloadToPush returns the payload on size or outset change") {
        let a = OverlayGeometry.targetPayloadJS(targetFrame: base, outset: 0)
        let resized = OverlayGeometry.targetPayloadJS(
            targetFrame: CGRect(x: 100, y: 200, width: 500, height: 300), outset: 0)
        let outset = OverlayGeometry.targetPayloadJS(targetFrame: base, outset: 6)
        try expect(OverlayTickPlan.payloadToPush(resized, lastPushed: a) == resized)
        try expect(OverlayTickPlan.payloadToPush(outset, lastPushed: a) == outset)
    }

    test("OverlayTickPlan.payloadToPush returns the payload when nothing was pushed yet") {
        let js = OverlayGeometry.targetPayloadJS(targetFrame: base, outset: 0)
        try expect(OverlayTickPlan.payloadToPush(js, lastPushed: nil) == js)
    }

    test("OverlayTickPlan.needsAppKitSync only once motion has stopped") {
        // An out-of-band (window-server) move leaves AppKit's cached frame
        // stale; resync on the first idle tick, never mid-motion.
        try expect(OverlayTickPlan.needsAppKitSync(frameOp: .none, appKitStale: true))
        try expect(!OverlayTickPlan.needsAppKitSync(frameOp: .move(.zero), appKitStale: true))
        try expect(!OverlayTickPlan.needsAppKitSync(frameOp: .none, appKitStale: false))
    }

    test("OverlayTickPlan.needsAppKitSync is false on reshape (setFrame resyncs)") {
        try expect(!OverlayTickPlan.needsAppKitSync(frameOp: .reshape(.zero), appKitStale: true))
    }

    test("OverlayTickPlan.holdsHeadroom while the motion engine animates the target") {
        try expect(OverlayTickPlan.holdsHeadroom(liveResize: false, commanded: true))
        try expect(OverlayTickPlan.holdsHeadroom(liveResize: true, commanded: false))
        try expect(!OverlayTickPlan.holdsHeadroom(liveResize: false, commanded: false))
    }
}
