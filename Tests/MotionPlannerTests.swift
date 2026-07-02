import Foundation
import CoreGraphics

// MotionPlanner — the pure scheduling core of the window motion engine.
// Registrations accumulate between display-link ticks; the first tick a
// registration sees assigns its start time (so every window registered in
// one burst animates on an identical clock — the anti-stagger contract),
// and each tick returns the AX writes to issue plus finished animations.
func registerMotionPlannerTests() {
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    test("burst registrations share a start tick and progress in lockstep") {
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 100, 100), to: rect(1000, 0, 100, 100),
                       duration: 1.0, easing: .linear)
        _ = p.register(windowID: 2, from: rect(0, 500, 100, 100), to: rect(1000, 500, 100, 100),
                       duration: 1.0, easing: .linear)

        // First tick assigns start times; both windows are still at `from`,
        // so no writes are due.
        let first = p.tick(now: 10.0)
        try expectEqual(first.writes.count, 0, "t=0 should suppress from-frame writes")

        // Halfway: both windows must be at the identical eased progress.
        let mid = p.tick(now: 10.5)
        try expectEqual(mid.writes.count, 2)
        for w in mid.writes {
            try expectEqual(w.frame.origin.x, 500, "window \(w.windowID) not at lockstep midpoint")
            try expect(!w.isFinal, "midpoint write flagged final")
        }
    }

    test("final tick writes exact target, flags isFinal, and empties the table") {
        var p = MotionPlanner()
        _ = p.register(windowID: 7, from: rect(0, 0, 100, 100), to: rect(300, 40, 640, 480),
                       duration: 0.2, easing: .easeOutCubic)
        _ = p.tick(now: 0)
        let done = p.tick(now: 5.0)
        try expectEqual(done.writes.count, 1)
        try expectEqual(done.writes[0].frame, rect(300, 40, 640, 480))
        try expect(done.writes[0].isFinal, "settle write must be final")
        try expectEqual(done.finished.count, 1)
        try expect(done.finished[0].settled, "settle must report settled=true")
        try expect(p.isEmpty, "planner not empty after settle")
        try expect(!p.isAnimating(7), "still animating after settle")
    }

    test("supersede is last-write-wins and reports the old registration") {
        var p = MotionPlanner()
        let a = p.register(windowID: 3, from: rect(0, 0, 100, 100), to: rect(1000, 0, 100, 100),
                           duration: 1.0, easing: .linear)
        try expectEqual(a.superseded, nil)
        _ = p.tick(now: 0)
        _ = p.tick(now: 0.5) // in flight at x=500

        let b = p.register(windowID: 3, from: rect(0, 0, 100, 100), to: rect(200, 0, 100, 100),
                           duration: 1.0, easing: .linear)
        guard let old = b.superseded else { throw Expectation(message: "no superseded report") }
        try expectEqual(old.key, a.key)
        try expect(!old.settled, "superseded must report settled=false")

        // The replacement starts from the in-flight frame (x≈500), not the
        // stale original `from`, and heads to the new target.
        _ = p.tick(now: 0.5)
        let mid = p.tick(now: 1.0)
        try expectEqual(mid.writes.count, 1)
        let x = mid.writes[0].frame.origin.x
        try expect(x < 500 && x > 200, "expected motion from ~500 toward 200, got \(x)")
        let done = p.tick(now: 9.0)
        try expectEqual(done.writes.first?.frame.origin.x, 200)
    }

    test("spring supersede seeds velocity carryover") {
        var p = MotionPlanner()
        _ = p.register(windowID: 4, from: rect(0, 0, 100, 100), to: rect(800, 0, 100, 100),
                       duration: 0, easing: .spring)
        _ = p.tick(now: 0)
        _ = p.tick(now: 0.03) // in flight, moving +x fast

        _ = p.register(windowID: 4, from: rect(0, 0, 100, 100), to: rect(820, 0, 100, 100),
                       duration: 0, easing: .spring)
        _ = p.tick(now: 0.03)
        // With carried +x velocity the very next instant keeps moving in +x
        // from the handoff point rather than restarting from rest.
        let before = p.tick(now: 0.031).writes.first?.frame.origin.x
        let after = p.tick(now: 0.05).writes.first?.frame.origin.x
        if let b = before, let a = after {
            try expect(a > b, "carried velocity should keep +x motion (\(b) → \(a))")
        }
        let done = p.tick(now: 5.0)
        try expectEqual(done.writes.first?.frame.origin.x, 820, "spring must settle at new target")
    }

    test("cancel stops ticking and reports settled=false") {
        var p = MotionPlanner()
        let r = p.register(windowID: 9, from: rect(0, 0, 100, 100), to: rect(500, 0, 100, 100),
                           duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        guard let cancelled = p.cancel(windowID: 9) else { throw Expectation(message: "cancel found nothing") }
        try expectEqual(cancelled.key, r.key)
        try expect(!cancelled.settled)
        try expect(p.isEmpty)
        try expectEqual(p.tick(now: 0.5).writes.count, 0)
    }

    test("unchanged rounded frames are not re-written") {
        var p = MotionPlanner()
        // 10px over 10s = 1px/s; two ticks 100ms apart round to the same px.
        _ = p.register(windowID: 5, from: rect(0, 0, 100, 100), to: rect(10, 0, 100, 100),
                       duration: 10.0, easing: .linear)
        _ = p.tick(now: 0)
        let a = p.tick(now: 1.0)
        try expectEqual(a.writes.count, 1, "1px progress should write once")
        let b = p.tick(now: 1.05)
        try expectEqual(b.writes.count, 0, "sub-pixel progress must not re-write")
    }

    test("degenerate no-move registration settles on first tick") {
        var p = MotionPlanner()
        let f = rect(50, 50, 300, 200)
        _ = p.register(windowID: 6, from: f, to: f, duration: 0.3, easing: .easeOutCubic)
        let out = p.tick(now: 0)
        try expectEqual(out.writes.count, 1, "no-move should still assert the frame once")
        try expect(out.writes[0].isFinal)
        try expectEqual(out.finished.count, 1)
        try expect(p.isEmpty)
    }

    test("isAnimating reflects registration lifetime") {
        var p = MotionPlanner()
        try expect(!p.isAnimating(11))
        _ = p.register(windowID: 11, from: rect(0, 0, 10, 10), to: rect(90, 0, 10, 10),
                       duration: 0.5, easing: .linear)
        try expect(p.isAnimating(11))
        _ = p.tick(now: 0)
        _ = p.tick(now: 10)
        try expect(!p.isAnimating(11))
    }
}
