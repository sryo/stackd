import Foundation
import CoreGraphics

// Tests for `LiveResizeDetector` in `Sources/DataSources/Overlay.swift` —
// "is the user dragging this window's edge right now?", observed from the
// overlay tick so a stack can hide or simplify its overlay while the
// target resizes, and the `resizing` flag it adds to the sd.target payload.

func registerLiveResizeDetectorTests() {
    let a = CGSize(width: 400, height: 300)
    let b = CGSize(width: 420, height: 300)

    test("LiveResizeDetector: size change with the button down is resizing") {
        var d = LiveResizeDetector()
        _ = d.update(size: a, now: 0, buttonDown: { true })
        try expect(d.update(size: b, now: 0.016, buttonDown: { true }))
    }

    test("LiveResizeDetector: stays resizing through short pauses, settles after 60ms") {
        var d = LiveResizeDetector()
        _ = d.update(size: a, now: 0, buttonDown: { true })
        _ = d.update(size: b, now: 1.0, buttonDown: { true })
        try expect(d.update(size: b, now: 1.03, buttonDown: { true }), "30ms pause is still a resize")
        try expect(!d.update(size: b, now: 1.07, buttonDown: { true }), "70ms quiet has settled")
    }

    test("LiveResizeDetector: button up ends the resize immediately") {
        var d = LiveResizeDetector()
        _ = d.update(size: a, now: 0, buttonDown: { true })
        _ = d.update(size: b, now: 0.016, buttonDown: { true })
        try expect(!d.update(size: b, now: 0.02, buttonDown: { false }))
    }

    test("LiveResizeDetector: programmatic resize (no button) is not a live resize") {
        var d = LiveResizeDetector()
        _ = d.update(size: a, now: 0, buttonDown: { false })
        try expect(!d.update(size: b, now: 0.016, buttonDown: { false }))
    }

    test("LiveResizeDetector: doesn't query the button when nothing resized recently") {
        var d = LiveResizeDetector()
        var queried = false
        _ = d.update(size: a, now: 0, buttonDown: { queried = true; return true })
        queried = false
        _ = d.update(size: a, now: 5, buttonDown: { queried = true; return true })
        try expect(!queried, "idle ticks must not hit the window server")
    }

    test("targetObjectJS adds resizing:true only while resizing") {
        let f = CGRect(x: 0, y: 0, width: 640, height: 480)
        try expectEqual(OverlayGeometry.targetObjectJS(targetFrame: f, outset: 0),
                        "{x:0,y:0,w:640,h:480,outset:0}")
        try expectEqual(OverlayGeometry.targetObjectJS(targetFrame: f, outset: 0, resizing: true),
                        "{x:0,y:0,w:640,h:480,outset:0,resizing:true}")
    }
}
