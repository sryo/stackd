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

func registerFrameLedgerMinSizeTests() {
    func rect(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: w, height: h) }
    func refuse(_ l: FrameLedger, _ target: CGRect, _ observed: CGRect) {
        _ = l.verify(windowID: 5, target: target, observed: observed)
        _ = l.verify(windowID: 5, target: target, observed: observed)
    }

    test("minSize: nothing learned, nothing known") {
        try expect(FrameLedger().minSize(windowID: 5) == nil)
    }

    test("minSize: a terminal refusal held above the target learns that axis only") {
        let l = FrameLedger()
        refuse(l, rect(200, 600), rect(320, 600))
        let m = l.minSize(windowID: 5)
        try expectEqual(m?.width, 320)
        try expectEqual(m?.height, nil)
    }

    test("minSize: the first read-back before the retry teaches nothing") {
        let l = FrameLedger()
        _ = l.verify(windowID: 5, target: rect(200, 600), observed: rect(320, 600))
        try expect(l.minSize(windowID: 5) == nil)
    }

    test("minSize: survives writes toward other sizes") {
        let l = FrameLedger()
        refuse(l, rect(200, 600), rect(320, 600))
        _ = l.enforcedSize(windowID: 5, targetSize: CGSize(width: 500, height: 600))
        _ = l.verify(windowID: 5, target: rect(500, 600), observed: rect(500, 600))
        try expectEqual(l.minSize(windowID: 5)?.width, 320)
    }

    test("minSize: an accepted size below the floor forgets it; clear forgets all") {
        let l = FrameLedger()
        refuse(l, rect(200, 600), rect(320, 600))
        _ = l.verify(windowID: 5, target: rect(250, 600), observed: rect(250, 600))
        try expect(l.minSize(windowID: 5) == nil)
        refuse(l, rect(200, 600), rect(320, 600))
        l.clear(windowID: 5)
        try expect(l.minSize(windowID: 5) == nil)
    }

    test("minSize: a grid snap above the target is not a floor") {
        let l = FrameLedger()
        refuse(l, rect(800, 600), rect(808, 600))
        try expect(l.minSize(windowID: 5) == nil)
    }
}
