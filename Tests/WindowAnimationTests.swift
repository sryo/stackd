import Foundation
import CoreGraphics

// WindowAnimationWatch — pure core of the early "animating" signal. After a
// CGS 1327 (animation began) the watch samples every frame; a tracked window
// whose window-list size differs from SkyLight's own frame is mid-animation
// (the genie warps the listed bounds, never the window's own frame). The
// signal follows the warp: it ends on the first frame the sizes match again
// (deminimize), and bridges the window leaving the screen (minimize).
func registerWindowAnimationTests() {
    let own = CGRect(x: 100, y: 100, width: 800, height: 600)
    let W = WindowAnimationWatch.self

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
        try expect(w.isWatching(now: 10 + W.watchDuration - 0.01))
        try expect(!w.isWatching(now: 10 + W.watchDuration))
        try expect(w.begin(now: 20), "a begin after the watch closed opens a new one")
        try expect(!w.begin(now: 20.2), "a begin inside an open watch only extends it")
        try expect(w.isWatching(now: 20.2 + W.watchDuration - 0.01))
    }

    test("sample announces a window once per animation") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        try expectEqual(w.sample(warped: [1], listed: [1, 2], now: 0.016), [1], "first sighting announces")
        try expectEqual(w.sample(warped: [1], listed: [1, 2], now: 0.032), [],
                        "later frames of the same animation stay quiet")
        try expectEqual(w.sample(warped: [1, 2], listed: [1, 2], now: 0.048), [2], "windows are independent")
    }

    test("a warped window reads animating; untouched windows don't") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1, 2], now: 0.016)
        try expect(w.isAnimating(1, now: 0.02))
        try expect(!w.isAnimating(2, now: 0.02))
    }

    test("deminimize: animating ends on the first frame the sizes match again — no sticky hold") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        var t = 0.016
        while t < 0.5 {
            _ = w.sample(warped: [1], listed: [1], now: t)
            try expect(w.isAnimating(1, now: t))
            t += 0.016
        }
        _ = w.sample(warped: [], listed: [1], now: t)
        try expect(!w.isAnimating(1, now: t), "sizes match: the overlay may come back this frame")
    }

    test("a missed sample doesn't end a warp early, but a stale one expires") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1], now: 0.1)
        try expect(w.isAnimating(1, now: 0.1 + W.freshness - 0.01))
        try expect(!w.isAnimating(1, now: 0.1 + W.freshness + 0.01))
        try expect(W.freshness < 0.2, "only bridges a couple of dropped frames")
    }

    test("minimize: a warped window leaving the screen stays animating across the hand-off") {
        // The genie ends with the window gone from the on-screen list; the
        // overlay must not flash back before SkyLight reports it ordered out.
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1], now: 0.5)
        _ = w.sample(warped: [], listed: [], now: 0.516)
        try expect(w.isAnimating(1, now: 0.516 + W.vanishHold - 0.01))
        try expect(!w.isAnimating(1, now: 0.516 + W.vanishHold + 0.01))
        try expect(W.vanishHold > W.freshness)
    }

    test("the watch keeps sampling while a window is still warped, past watchDuration") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        var t = 0.016
        while t < 0.9 {
            _ = w.sample(warped: [1], listed: [1], now: t)
            try expect(w.isWatching(now: t + 0.001), "still warped at \(t)")
            t += 0.016
        }
        _ = w.sample(warped: [], listed: [1], now: t)
        try expect(!w.isWatching(now: t + 0.001), "warp over and past watchDuration: stop sampling")
    }

    test("a window that never un-warps stops being sampled at the cap") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        var t = 0.016
        while t < W.maxWatch {
            _ = w.sample(warped: [1], listed: [1], now: t)
            t += 0.016
        }
        try expect(!w.isWatching(now: W.maxWatch + 0.001))
        try expect(W.maxWatch >= 1 && W.maxWatch <= 2)
    }

    test("stackd's own minimize reads animating before the warp shows, once") {
        var w = WindowAnimationWatch()
        try expect(w.expect(1, now: 0), "announce at the call")
        try expect(!w.expect(1, now: 0.01), "already announced")
        try expect(w.isWatching(now: 0.01), "sampling starts without waiting for 1327")
        _ = w.sample(warped: [], listed: [1], now: 0.016)
        try expect(w.isAnimating(1, now: 0.016), "unwarped frames before the genie starts don't end it")
        try expectEqual(w.sample(warped: [1], listed: [1], now: 0.05), [], "the warp isn't a second announcement")
        try expect(w.isAnimating(1, now: 0.05))
    }

    test("stackd's own minimize that never animates stops reading animating") {
        var w = WindowAnimationWatch()
        _ = w.expect(1, now: 0)
        try expect(!w.isAnimating(1, now: W.watchDuration + 0.01))
    }

    test("a window that animates again after its animation ended announces again") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1], now: 0.1)
        _ = w.sample(warped: [], listed: [1], now: 0.2)
        _ = w.begin(now: 3)
        try expectEqual(w.sample(warped: [1], listed: [1], now: 3.1), [1])
    }

    test("prune drops finished animations only") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1, 2], listed: [1, 2], now: 0.1)
        _ = w.sample(warped: [2], listed: [2], now: 0.2)
        w.prune(now: 0.2 + 0.01)
        try expect(!w.isAnimating(1, now: 0.21))
        try expect(w.isAnimating(2, now: 0.21))
    }
}
