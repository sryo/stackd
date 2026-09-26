import Foundation
import CoreGraphics

// setFrame(id, frame, {live: true}): the routing decision, the planned
// mailbox write, the non-forgetting refusal lookup it reads, and the
// mailbox collapsing a stream of live writes to the newest.
func registerLiveFrameWriteTests() {
    func route(duration: Double = 0, easing: MotionEasing? = nil, live: Bool,
               reduceMotion: Bool = false) -> MotionRouting.Route {
        MotionRouting.route(duration: duration, easing: easing, live: live,
                            reduceMotion: reduceMotion, respectReduceMotion: true)
    }

    test("live routing: no options stays the synchronous instant write") {
        try expectEqual(route(live: false), .instant)
    }

    test("live routing: live with no duration goes through the mailbox") {
        try expectEqual(route(live: true), .live)
        try expectEqual(route(easing: .linear, live: true), .live, "an easing without a duration is instant")
    }

    test("live routing: a duration or spring still animates") {
        try expectEqual(route(duration: 0.2, live: true), .animate)
        try expectEqual(route(easing: .spring, live: true), .animate)
        try expectEqual(route(duration: 0.2, live: false), .animate)
    }

    test("live routing: Reduce Motion turns a live animation into a live write") {
        try expectEqual(route(duration: 0.2, live: true, reduceMotion: true), .live)
        try expectEqual(route(duration: 0.2, live: false, reduceMotion: true), .instant)
    }

    test("live write plan: an intermediate write of both axes, rounded") {
        let w = LiveFrameWrite.plan(windowID: 3, frame: CGRect(x: 10.4, y: 20.6, width: 400.2, height: 300),
                                    previous: nil, enforcedSize: nil)
        try expectEqual(w?.isFinal, false)
        try expectEqual(w?.frame, CGRect(x: 10, y: 21, width: 400, height: 300))
        try expectEqual(w?.writeSize, true)
        try expectEqual(w?.writePosition, true)
    }

    test("live write plan: a growing window moves before it grows") {
        let prev = CGRect(x: 500, y: 0, width: 400, height: 600)
        let grow = LiveFrameWrite.plan(windowID: 3, frame: CGRect(x: 480, y: 0, width: 420, height: 600),
                                       previous: prev, enforcedSize: nil)
        try expectEqual(grow?.order, .positionThenSize)
        let shrink = LiveFrameWrite.plan(windowID: 3, frame: CGRect(x: 520, y: 0, width: 380, height: 600),
                                         previous: prev, enforcedSize: nil)
        try expectEqual(shrink?.order, .sizeThenPosition)
    }

    test("live write plan: a refused size writes the position only, at the enforced size") {
        let w = LiveFrameWrite.plan(windowID: 3, frame: CGRect(x: 600, y: 0, width: 200, height: 600),
                                    previous: nil, enforcedSize: CGSize(width: 320, height: 600))
        try expectEqual(w?.writeSize, false)
        try expectEqual(w?.writePosition, true)
        try expectEqual(w?.frame.size, CGSize(width: 320, height: 600))
    }

    test("FrameLedger: peeking a different target size keeps the refusal") {
        let l = FrameLedger()
        let target = CGRect(x: 0, y: 0, width: 200, height: 600)
        let clamped = CGRect(x: 0, y: 0, width: 320, height: 600)
        _ = l.verify(windowID: 9, target: target, observed: clamped)
        _ = l.verify(windowID: 9, target: target, observed: clamped)
        try expectEqual(l.peekEnforcedSize(windowID: 9, targetSize: CGSize(width: 250, height: 600)), nil)
        try expectEqual(l.peekEnforcedSize(windowID: 9, targetSize: target.size), clamped.size)
        try expectEqual(l.enforcedSize(windowID: 9, targetSize: target.size), clamped.size,
                        "the peek did not forget it")
    }

    test("mailbox: live writes queued behind a drain collapse to the newest, every caller resolved") {
        var m = MotionWriteMailbox()
        func live(_ x: Double, _ cb: UInt64) -> MotionWriteMailbox.Entry {
            let w = LiveFrameWrite.plan(windowID: 4, frame: CGRect(x: x, y: 0, width: 400, height: 600),
                                        previous: nil, enforcedSize: nil)!
            return MotionWriteMailbox.Entry(write: w, generation: 0, callbacks: [cb])
        }
        try expect(m.post(live(100, 1)))
        _ = m.take()
        try expect(!m.post(live(110, 2)))
        try expect(!m.post(live(120, 3)))
        try expect(!m.post(live(130, 4)))
        try expect(m.finish())
        let next = m.take()
        try expectEqual(next.count, 1)
        try expectEqual(next[0].write.frame.origin.x, 130)
        try expectEqual(next[0].callbacks, [2, 3, 4])
    }
}
