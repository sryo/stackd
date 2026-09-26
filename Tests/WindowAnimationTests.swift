import Foundation
import CoreGraphics

// WindowAnimationWatch — pure core of the early "animating" signal. After a
// CGS 1327 (animation began) the watch stays open briefly; a tracked window
// whose window-list size differs from SkyLight's own frame is mid-animation
// (the genie warps the listed bounds, never the window's own frame).
func registerWindowAnimationTests() {
    let own = CGRect(x: 100, y: 100, width: 800, height: 600)

    test("isAnimating(listed:own:) — warped listed size means animating") {
        let warped = CGRect(x: 120, y: 300, width: 640, height: 420)
        try expect(WindowAnimationWatch.isAnimating(listed: warped, own: own))
    }

    test("isAnimating(listed:own:) — identical bounds are not animating") {
        try expect(!WindowAnimationWatch.isAnimating(listed: own, own: own))
    }

    test("isAnimating(listed:own:) — sub-point rounding is not animating") {
        let rounded = CGRect(x: 100, y: 100, width: 800.5, height: 599.5)
        try expect(!WindowAnimationWatch.isAnimating(listed: rounded, own: own))
    }

    test("isAnimating(listed:own:) — an origin-only difference is a move, not an animation") {
        let moved = own.offsetBy(dx: 40, dy: -30)
        try expect(!WindowAnimationWatch.isAnimating(listed: moved, own: own))
    }

    test("begin opens a watch for watchDuration; later begins extend it") {
        var w = WindowAnimationWatch()
        try expect(!w.isWatching(now: 0))
        try expect(w.begin(now: 10), "the first begin opens a watch")
        try expect(w.isWatching(now: 10 + WindowAnimationWatch.watchDuration - 0.01))
        try expect(!w.isWatching(now: 10 + WindowAnimationWatch.watchDuration))
        try expect(w.begin(now: 20), "a begin after the watch closed opens a new one")
        try expect(!w.begin(now: 20.2), "a begin inside an open watch only extends it")
        try expect(w.isWatching(now: 20.2 + WindowAnimationWatch.watchDuration - 0.01))
    }

    test("noteAnimating reports a window once while it is held animating") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        try expect(w.noteAnimating(1, now: 0.016), "first sighting reports")
        try expect(!w.noteAnimating(1, now: 0.032), "later frames of the same animation stay quiet")
        try expect(w.noteAnimating(2, now: 0.032), "windows are independent")
    }

    test("isAnimating(windowID) holds for holdDuration after the last sighting") {
        var w = WindowAnimationWatch()
        try expect(!w.isAnimating(1, now: 0))
        _ = w.noteAnimating(1, now: 1)
        try expect(w.isAnimating(1, now: 1 + WindowAnimationWatch.holdDuration - 0.01))
        try expect(!w.isAnimating(1, now: 1 + WindowAnimationWatch.holdDuration))
        try expect(!w.isAnimating(2, now: 1))
    }

    test("a window that animates again after its hold expired reports again") {
        var w = WindowAnimationWatch()
        _ = w.noteAnimating(1, now: 0)
        try expect(w.noteAnimating(1, now: WindowAnimationWatch.holdDuration + 0.1))
    }

    test("the hold outlasts the watch, covering the genie's full length") {
        try expect(WindowAnimationWatch.holdDuration > WindowAnimationWatch.watchDuration)
    }

    test("prune drops expired holds only") {
        var w = WindowAnimationWatch()
        _ = w.noteAnimating(1, now: 0)
        _ = w.noteAnimating(2, now: 0.5)
        w.prune(now: WindowAnimationWatch.holdDuration + 0.1)
        try expect(!w.isAnimating(1, now: WindowAnimationWatch.holdDuration + 0.1))
        try expect(w.isAnimating(2, now: WindowAnimationWatch.holdDuration + 0.1))
    }
}
