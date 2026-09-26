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
