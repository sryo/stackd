import Foundation
import CoreGraphics

// MotionWriteMailbox — the per-app write queue policy behind the motion
// engine's AX writers: latest frame wins per window, one drain in flight,
// and a drain that finishes with newer frames waiting asks to run again.
func registerMotionWriteMailboxTests() {
    func write(_ wid: CGWindowID, x: Double, final: Bool = false,
               size: Bool = true, position: Bool = true) -> MotionPlanner.FrameWrite {
        MotionPlanner.FrameWrite(windowID: wid, frame: CGRect(x: x, y: 0, width: 100, height: 100),
                                 isFinal: final, writeSize: size, writePosition: position)
    }
    typealias Entry = MotionWriteMailbox.Entry

    test("MotionWriteMailbox: the first post on an idle mailbox starts a drain") {
        var m = MotionWriteMailbox()
        try expect(m.post(Entry(write: write(1, x: 10), generation: 1)))
        let batch = m.take()
        try expectEqual(batch.map { $0.write.frame.origin.x }, [10])
        try expect(!m.post(Entry(write: write(1, x: 20), generation: 1)),
                   "a post during a drain must not start a second one")
    }

    test("MotionWriteMailbox: latest frame wins per window while a drain is in flight") {
        var m = MotionWriteMailbox()
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        _ = m.take()
        _ = m.post(Entry(write: write(1, x: 20), generation: 1))
        _ = m.post(Entry(write: write(2, x: 5), generation: 3))
        _ = m.post(Entry(write: write(1, x: 30), generation: 1))
        try expect(m.finish(), "newer frames arrived: the drain must reschedule")
        let next = m.take()
        try expectEqual(next.map { $0.write.windowID }, [1, 2], "first-seen order")
        try expectEqual(next.map { $0.write.frame.origin.x }, [30, 5])
    }

    test("MotionWriteMailbox: a replaced write keeps the axes it still owed") {
        var m = MotionWriteMailbox()
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        _ = m.take()
        _ = m.post(Entry(write: write(1, x: 20, size: true, position: false), generation: 1))
        _ = m.post(Entry(write: write(1, x: 30, size: false, position: true), generation: 1))
        _ = m.finish()
        let merged = m.take()[0].write
        try expect(merged.writeSize && merged.writePosition,
                   "the size change from the replaced write must still be written")
    }

    test("MotionWriteMailbox: callbacks of a replaced write ride on its replacement") {
        var m = MotionWriteMailbox()
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        _ = m.take()
        _ = m.post(Entry(write: write(1, x: 20, final: true), generation: 1, callbacks: [7]))
        _ = m.post(Entry(write: write(1, x: 40), generation: 2, callbacks: [9]))
        _ = m.finish()
        let e = m.take()[0]
        try expectEqual(e.callbacks, [7, 9])
        try expectEqual(e.generation, 2)
        try expect(!e.write.isFinal, "the newest write decides finality")
    }

    test("MotionWriteMailbox: a drain that finishes with nothing waiting goes idle") {
        var m = MotionWriteMailbox()
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        _ = m.take()
        try expect(!m.finish())
        try expect(m.isIdle)
        try expect(m.post(Entry(write: write(1, x: 11), generation: 1)),
                   "idle again: the next post starts a drain")
    }

    // One tick posts a write per animating window. The tick posts them all
    // and only then drains each app's mailbox once, so an app's windows go
    // out as one batch instead of the first window alone.
    func postTick(_ posts: [(pid: pid_t, wid: CGWindowID, x: Double)],
                  into boxes: inout [pid_t: MotionWriteMailbox]) -> MotionDrainRound {
        var round = MotionDrainRound()
        for p in posts {
            let entry = Entry(write: write(p.wid, x: p.x), generation: 1)
            if boxes[p.pid, default: MotionWriteMailbox()].post(entry) {
                round.noteStartsDrain(pid: p.pid)
            }
        }
        return round
    }
    func drainBatch(_ boxes: inout [pid_t: MotionWriteMailbox], _ pid: pid_t) throws -> [Entry] {
        guard let batch = boxes[pid]?.takeIfIdle() else {
            throw Expectation(message: "pid \(pid) had nothing to drain")
        }
        return batch
    }

    test("MotionDrainRound: one tick's writes for one app reach take() as one batch, in order") {
        var boxes: [pid_t: MotionWriteMailbox] = [:]
        let round = postTick([(7, 1, 10), (7, 2, 20), (7, 3, 30)], into: &boxes)
        try expectEqual(round.pids, [7], "the app is drained once, not once per window")
        let batch = try drainBatch(&boxes, 7)
        try expectEqual(batch.map { $0.write.windowID }, [1, 2, 3])
        try expectEqual(batch.map { $0.write.frame.origin.x }, [10, 20, 30])
    }

    test("MotionDrainRound: latest write per window wins within the tick's batch") {
        var boxes: [pid_t: MotionWriteMailbox] = [:]
        _ = postTick([(7, 1, 10), (7, 2, 20), (7, 1, 30)], into: &boxes)
        let batch = try drainBatch(&boxes, 7)
        try expectEqual(batch.map { $0.write.windowID }, [1, 2], "first-seen order")
        try expectEqual(batch.map { $0.write.frame.origin.x }, [30, 20])
    }

    test("MotionDrainRound: each app drains once, in the order the tick first touched it") {
        var boxes: [pid_t: MotionWriteMailbox] = [:]
        let round = postTick([(9, 1, 1), (4, 2, 1), (9, 3, 1), (4, 4, 1), (9, 5, 1)], into: &boxes)
        try expectEqual(round.pids, [9, 4])
        try expectEqual(try drainBatch(&boxes, 9).map { $0.write.windowID }, [1, 3, 5])
        try expectEqual(try drainBatch(&boxes, 4).map { $0.write.windowID }, [2, 4])
    }

    test("MotionDrainRound: an app with a drain in flight is not noted and keeps its writes for the finish") {
        var boxes: [pid_t: MotionWriteMailbox] = [:]
        _ = postTick([(7, 1, 10)], into: &boxes)
        _ = boxes[7]!.take()
        let round = postTick([(7, 1, 20), (7, 2, 20)], into: &boxes)
        try expect(round.pids.isEmpty, "the running drain picks these up when it finishes")
        try expect(boxes[7]!.takeIfIdle() == nil, "no second drain while one is in flight")
        try expect(boxes[7]!.finish())
        try expectEqual(boxes[7]!.take().map { $0.write.windowID }, [1, 2])
    }

    test("MotionWriteMailbox: takeIfIdle yields nothing for an empty mailbox or one with a drain in flight") {
        var m = MotionWriteMailbox()
        try expect(m.takeIfIdle() == nil, "an empty mailbox has nothing to drain")
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        _ = m.take()
        _ = m.post(Entry(write: write(2, x: 10), generation: 1))
        try expect(m.takeIfIdle() == nil, "a drain is running; it asks again at its finish")
    }

    test("MotionWriteMailbox: takeIfIdle on an idle mailbox starts a drain like take") {
        var m = MotionWriteMailbox()
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        try expectEqual(m.takeIfIdle()?.count, 1)
        try expect(m.draining)
        try expect(m.involves(1))
    }

    test("MotionWriteMailbox: involves reports pending and in-flight windows") {
        var m = MotionWriteMailbox()
        try expect(!m.involves(1))
        _ = m.post(Entry(write: write(1, x: 10), generation: 1))
        try expect(m.involves(1))
        _ = m.take()
        try expect(m.involves(1), "in flight")
        _ = m.post(Entry(write: write(2, x: 10), generation: 1))
        try expect(m.involves(2), "pending behind the drain")
        _ = m.finish()
        _ = m.take()
        try expect(!m.involves(1), "window 1's drain is done")
        _ = m.finish()
        try expect(!m.involves(2))
    }
}
