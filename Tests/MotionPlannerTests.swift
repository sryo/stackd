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

    test("isAnimating from registration until the final tick, which writes the exact target and empties the table") {
        var p = MotionPlanner()
        _ = p.register(windowID: 7, from: rect(0, 0, 100, 100), to: rect(300, 40, 640, 480),
                       duration: 0.2, easing: .easeOutCubic)
        try expect(p.isAnimating(7), "animating from registration on")
        _ = p.tick(now: 0)
        try expect(p.isAnimating(7))
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
        // A spring superseded mid-flight hands its velocity to the
        // replacement, which therefore runs ahead of a spring started from
        // rest at the same point toward the same target.
        var p = MotionPlanner()
        _ = p.register(windowID: 4, from: rect(0, 0, 100, 100), to: rect(800, 0, 100, 100),
                       duration: 0, easing: .spring)
        _ = p.tick(now: 0)
        _ = p.tick(now: 0.03) // in flight, moving +x fast
        _ = p.register(windowID: 4, from: rect(0, 0, 100, 100), to: rect(820, 0, 100, 100),
                       duration: 0, easing: .spring)
        _ = p.tick(now: 0.03)
        guard let carried = p.tick(now: 0.04).writes.first?.frame.origin.x else {
            throw Expectation(message: "no write from the replacement spring")
        }

        let handoff = MotionMath.Spring(from: 0, target: 800, initialVelocity: 0).value(at: 0.03)
        var rest = MotionPlanner()
        _ = rest.register(windowID: 4, from: rect(handoff, 0, 100, 100), to: rect(820, 0, 100, 100),
                          duration: 0, easing: .spring)
        _ = rest.tick(now: 0.03)
        guard let fromRest = rest.tick(now: 0.04).writes.first?.frame.origin.x else {
            throw Expectation(message: "no write from the at-rest spring")
        }
        try expect(carried > fromRest + 10, "carried velocity should run ahead (\(carried) vs \(fromRest))")

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

    test("translate-only intermediate writes skip the size axis") {
        // A size write makes the app re-layout; a pure tile shift must not
        // pay for one every frame.
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 400, 300), to: rect(800, 0, 400, 300),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        let mid = p.tick(now: 0.5)
        try expectEqual(mid.writes.count, 1)
        try expect(!mid.writes[0].writeSize, "size unchanged, must not be written")
        try expect(mid.writes[0].writePosition)
    }

    test("resize-only intermediate writes skip the position axis") {
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(100, 100, 400, 300), to: rect(100, 100, 800, 600),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        let mid = p.tick(now: 0.5)
        try expectEqual(mid.writes.count, 1)
        try expect(mid.writes[0].writeSize)
        try expect(!mid.writes[0].writePosition, "origin unchanged, must not be written")
    }

    test("mixed move+resize writes both axes, and the final write always writes both") {
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 400, 300), to: rect(800, 0, 400, 300),
                       duration: 0.2, easing: .linear)
        _ = p.register(windowID: 2, from: rect(0, 0, 400, 300), to: rect(200, 50, 600, 400),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        let mid = p.tick(now: 0.1)
        let mixed = mid.writes.first { $0.windowID == 2 }
        try expect(mixed?.writeSize == true && mixed?.writePosition == true)
        let done = p.tick(now: 5.0)
        let final1 = done.writes.first { $0.windowID == 1 }
        try expect(final1?.isFinal == true)
        try expect(final1?.writeSize == true && final1?.writePosition == true,
                   "settle frame must write both axes")
    }

    test("a stalled window gets no more intermediate writes but still settles") {
        // A hung app times out an intermediate write; retrying every frame
        // would stall main for the whole animation. Skip to the final frame.
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 400, 300), to: rect(800, 0, 400, 300),
                       duration: 1.0, easing: .linear)
        _ = p.register(windowID: 2, from: rect(0, 400, 400, 300), to: rect(800, 400, 400, 300),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        p.markStalled(windowID: 1)
        let mid = p.tick(now: 0.5)
        try expect(mid.writes.allSatisfy { $0.windowID == 2 }, "stalled window must not write mid-flight")
        let done = p.tick(now: 5.0)
        let final1 = done.writes.first { $0.windowID == 1 }
        try expect(final1?.isFinal == true && final1?.frame == rect(800, 0, 400, 300))
    }

    test("a superseding registration clears the stall") {
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 400, 300), to: rect(800, 0, 400, 300),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        p.markStalled(windowID: 1)
        _ = p.register(windowID: 1, from: rect(0, 0, 400, 300), to: rect(0, 0, 400, 300).offsetBy(dx: 600, dy: 0),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 1)
        let mid = p.tick(now: 1.5)
        try expect(mid.writes.contains { $0.windowID == 1 && !$0.isFinal })
    }

    test("an enforced size turns intermediate steps into position-only writes") {
        let step = MotionPlanner.FrameWrite(windowID: 1, frame: rect(100, 50, 600, 400), isFinal: false)
        let pinned = step.honoring(enforcedSize: CGSize(width: 232, height: 231))
        try expectEqual(pinned?.frame, rect(100, 50, 232, 231))
        try expectEqual(pinned?.writeSize, false)
        try expectEqual(pinned?.writePosition, true)
    }

    test("a size-only step at an enforced size writes nothing") {
        let step = MotionPlanner.FrameWrite(windowID: 1, frame: rect(100, 50, 600, 400), isFinal: false,
                                            writeSize: true, writePosition: false)
        try expectEqual(step.honoring(enforcedSize: CGSize(width: 232, height: 231)), nil)
    }

    test("the settle frame at an enforced size still writes both axes") {
        let final = MotionPlanner.FrameWrite(windowID: 1, frame: rect(100, 50, 600, 400), isFinal: true)
        let pinned = final.honoring(enforcedSize: CGSize(width: 232, height: 231))
        try expectEqual(pinned?.frame, rect(100, 50, 232, 231))
        try expect(pinned?.writeSize == true && pinned?.writePosition == true)
    }

    test("no enforced size leaves the write alone") {
        let step = MotionPlanner.FrameWrite(windowID: 1, frame: rect(100, 50, 600, 400), isFinal: false)
        try expectEqual(step.honoring(enforcedSize: nil), step)
    }

    test("FrameWriteOrder: growing writes position first, shrinking writes size first") {
        let base = rect(100, 100, 400, 300)
        try expectEqual(FrameWriteOrder.pick(current: base, target: rect(0, 0, 800, 300)), .positionThenSize)
        try expectEqual(FrameWriteOrder.pick(current: base, target: rect(0, 0, 400, 301)), .positionThenSize)
        try expectEqual(FrameWriteOrder.pick(current: base, target: rect(500, 0, 200, 300)), .sizeThenPosition)
        try expectEqual(FrameWriteOrder.pick(current: base, target: rect(500, 0, 400, 300)), .sizeThenPosition,
                        "a pure move has nothing to grow")
        try expectEqual(FrameWriteOrder.pick(current: base, target: rect(0, 0, 800, 100)), .positionThenSize,
                        "any growing axis puts position first")
        try expectEqual(FrameWriteOrder.pick(current: nil, target: base), .sizeThenPosition)
    }

    test("planned writes carry the order for their step") {
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 400, 300), to: rect(0, 0, 800, 600),
                       duration: 1.0, easing: .linear)
        _ = p.register(windowID: 2, from: rect(0, 0, 800, 600), to: rect(0, 0, 400, 300),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0)
        let mid = p.tick(now: 0.5)
        try expectEqual(mid.writes.first { $0.windowID == 1 }?.order, .positionThenSize)
        try expectEqual(mid.writes.first { $0.windowID == 2 }?.order, .sizeThenPosition)
        let done = p.tick(now: 2)
        try expectEqual(done.writes.first { $0.windowID == 1 }?.order, .positionThenSize)
        try expectEqual(done.writes.first { $0.windowID == 2 }?.order, .sizeThenPosition)
    }

    test("settle: a third size set only when the read-back size is off") {
        let target = rect(0, 0, 800, 600)
        try expect(!FrameWriteOrder.needsSizeReassert(target: target, readBack: CGSize(width: 800, height: 600)))
        try expect(!FrameWriteOrder.needsSizeReassert(target: target, readBack: CGSize(width: 800.5, height: 599.5)))
        try expect(FrameWriteOrder.needsSizeReassert(target: target, readBack: CGSize(width: 780, height: 600)))
        try expect(!FrameWriteOrder.needsSizeReassert(target: target, readBack: nil),
                   "an unreadable size is not evidence of a mismatch")
    }

    test("MotionRouting: duration or spring animates when Reduce Motion is off") {
        try expect(MotionRouting.animates(duration: 0.25, easing: nil, reduceMotion: false, respectReduceMotion: true))
        try expect(MotionRouting.animates(duration: 0, easing: .spring, reduceMotion: false, respectReduceMotion: true))
        try expect(!MotionRouting.animates(duration: 0, easing: nil, reduceMotion: false, respectReduceMotion: true))
        try expect(!MotionRouting.animates(duration: 0, easing: .linear, reduceMotion: false, respectReduceMotion: true))
    }

    test("MotionRouting: Reduce Motion collapses animations to an instant write") {
        try expect(!MotionRouting.animates(duration: 0.25, easing: nil, reduceMotion: true, respectReduceMotion: true))
        try expect(!MotionRouting.animates(duration: 0, easing: .spring, reduceMotion: true, respectReduceMotion: true))
    }

    test("MotionRouting: a caller can opt out of honoring Reduce Motion") {
        try expect(MotionRouting.animates(duration: 0.25, easing: nil, reduceMotion: true, respectReduceMotion: false))
        try expect(MotionRouting.animates(duration: 0, easing: .spring, reduceMotion: true, respectReduceMotion: false))
    }

    test("a tick scoped to some windows leaves the others unstarted") {
        var p = MotionPlanner()
        _ = p.register(windowID: 1, from: rect(0, 0, 100, 100), to: rect(1000, 0, 100, 100),
                       duration: 1.0, easing: .linear)
        _ = p.register(windowID: 2, from: rect(0, 500, 100, 100), to: rect(1000, 500, 100, 100),
                       duration: 1.0, easing: .linear)
        _ = p.tick(now: 0, only: [1])
        let a = p.tick(now: 0.5, only: [1])
        try expectEqual(a.writes.map { $0.windowID }, [1])
        // Window 2's clock starts on the first tick that covers it.
        _ = p.tick(now: 0.5, only: [2])
        let b = p.tick(now: 1.0, only: [2])
        try expectEqual(b.writes.first?.frame.origin.x, 500, "window 2 started at 0.5, not 0")
    }

    test("windows sharing a scoped clock still start in lockstep") {
        var p = MotionPlanner()
        for wid in [CGWindowID(1), 2, 3] {
            _ = p.register(windowID: wid, from: rect(0, Double(wid) * 200, 100, 100),
                           to: rect(1000, Double(wid) * 200, 100, 100), duration: 1.0, easing: .linear)
        }
        _ = p.tick(now: 3, only: [1, 2])
        let mid = p.tick(now: 3.25, only: [1, 2])
        try expectEqual(Set(mid.writes.map { $0.frame.origin.x }), [250])
        try expectEqual(Set(mid.writes.map { $0.windowID }), [1, 2])
        try expectEqual(p.windowIDs, [1, 2, 3])
    }

    test("MotionClock: a window ticks on the display holding its target's center") {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: rect(0, 0, 1440, 900)),
            (id: 2, bounds: rect(1440, 0, 2560, 1440)),
        ]
        try expectEqual(MotionClock.display(for: rect(100, 100, 400, 300), displays: displays), 1)
        try expectEqual(MotionClock.display(for: rect(1300, 100, 800, 300), displays: displays), 2,
                        "straddling: the center decides")
    }

    test("MotionClock: a target off every display takes the one it overlaps most, else none") {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: rect(0, 0, 1440, 900)),
            (id: 2, bounds: rect(1440, 0, 2560, 1440)),
        ]
        try expectEqual(MotionClock.display(for: rect(1400, 1300, 400, 400), displays: displays), 2)
        try expectEqual(MotionClock.display(for: rect(-5000, -5000, 100, 100), displays: displays), nil)
    }
}
