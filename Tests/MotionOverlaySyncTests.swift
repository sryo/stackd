import Foundation
import CoreGraphics

// MotionOverlaySync — what an overlay attached to an animating window does
// when one of the motion engine's AX writes for that window lands: follow
// the frame the app just applied, go back to live reads after the settle
// frame, or leave the panel where it is.
func registerMotionOverlaySyncTests() {
    let frame = CGRect(x: 40, y: 60, width: 800, height: 500)
    func write(final: Bool = false) -> MotionPlanner.FrameWrite {
        MotionPlanner.FrameWrite(windowID: 7, frame: frame, isFinal: final)
    }

    test("MotionOverlaySync: a landed step of the current animation moves the overlay to it") {
        try expectEqual(MotionOverlaySync.onLanded(write(), generation: 3, timedOut: false, current: 3),
                        .follow(frame))
    }

    test("MotionOverlaySync: a step the app didn't apply in time leaves the overlay") {
        try expectEqual(MotionOverlaySync.onLanded(write(), generation: 3, timedOut: true, current: 3),
                        .none)
    }

    test("MotionOverlaySync: a step from a superseded or finished animation leaves the overlay") {
        try expectEqual(MotionOverlaySync.onLanded(write(), generation: 3, timedOut: false, current: 4),
                        .none)
        try expectEqual(MotionOverlaySync.onLanded(write(), generation: 3, timedOut: false, current: nil),
                        .none, "the settle frame is already queued behind it")
    }

    test("MotionOverlaySync: the landed settle frame hands the overlay back to live reads") {
        try expectEqual(MotionOverlaySync.onLanded(write(final: true), generation: 3, timedOut: false,
                                                   current: nil),
                        .end)
    }

    test("MotionOverlaySync: a settle frame landing after a new animation began leaves the overlay to it") {
        try expectEqual(MotionOverlaySync.onLanded(write(final: true), generation: 3, timedOut: false,
                                                   current: 5),
                        .none)
    }
}
