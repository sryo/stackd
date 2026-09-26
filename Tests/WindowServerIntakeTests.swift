import Foundation

// Tests for the pure merge policy behind `WindowServerIntake`
// (Sources/DataSources/WindowServerIntake.swift): `IntakeQueue` merges
// pending events per (kind, id), keeps the first event's enqueue time and
// arrival position, and hands the batch over in one take per drain;
// `IntakeEvent.key` maps each window-server event onto its merge key.

func registerWindowServerIntakeTests() {
    let a = IntakeKey(kind: .frame, id: 100)
    let b = IntakeKey(kind: .frame, id: 200)

    // MARK: IntakeQueue

    test("IntakeQueue: the first offer asks for a drain, later ones don't") {
        var q = IntakeQueue<String>()
        try expect(q.offer(a, "x", now: nil))
        try expect(!q.offer(b, "y", now: nil))
        try expect(!q.offer(a, "z", now: nil))
    }

    test("IntakeQueue: repeats of one key merge into a single item") {
        var q = IntakeQueue<String>()
        _ = q.offer(a, "first", now: nil)
        _ = q.offer(a, "second", now: nil)
        _ = q.offer(a, "third", now: nil)
        let batch = q.take()
        try expectEqual(batch.count, 1)
        try expectEqual(batch[0].payload, "third")
        try expectEqual(batch[0].count, 3)
    }

    test("IntakeQueue: a merged item keeps the first enqueue time") {
        var q = IntakeQueue<String>()
        _ = q.offer(a, "x", now: 1_000)
        _ = q.offer(a, "y", now: 5_000)
        try expectEqual(q.take()[0].firstEnqueued, 1_000)
    }

    test("IntakeQueue: no clock, no enqueue time") {
        var q = IntakeQueue<String>()
        _ = q.offer(a, "x", now: nil)
        try expectEqual(q.take()[0].firstEnqueued, nil)
    }

    test("IntakeQueue: items drain in first-arrival order") {
        var q = IntakeQueue<String>()
        _ = q.offer(b, "b", now: nil)
        _ = q.offer(a, "a", now: nil)
        _ = q.offer(b, "b2", now: nil)
        try expectEqual(q.take().map { $0.key }, [b, a])
    }

    test("IntakeQueue: same id under different kinds stays separate") {
        var q = IntakeQueue<String>()
        _ = q.offer(IntakeKey(kind: .frame, id: 7), "f", now: nil)
        _ = q.offer(IntakeKey(kind: .reordered, id: 7), "r", now: nil)
        try expectEqual(q.take().count, 2)
    }

    test("IntakeQueue: take empties the queue, so the next offer asks for a drain again") {
        var q = IntakeQueue<String>()
        _ = q.offer(a, "x", now: nil)
        _ = q.take()
        try expect(q.isEmpty)
        try expectEqual(q.take().count, 0)
        try expect(q.offer(a, "y", now: nil))
    }

    // MARK: IntakeEvent.key

    test("IntakeEvent.key: 806 and 807 for one wid share the frame key") {
        try expectEqual(IntakeEvent.window(.moved(wid: 5)).key, IntakeKey(kind: .frame, id: 5))
        try expectEqual(IntakeEvent.window(.resized(wid: 5)).key, IntakeKey(kind: .frame, id: 5))
    }

    test("IntakeEvent.key: per-window events key on their wid") {
        try expectEqual(IntakeEvent.window(.reordered(wid: 8)).key, IntakeKey(kind: .reordered, id: 8))
        try expectEqual(IntakeEvent.window(.destroyed(wid: 9)).key, IntakeKey(kind: .destroyed, id: 9))
        try expectEqual(IntakeEvent.window(.spaceWindowCreated(wid: 3, spaceID: 44)).key,
                        IntakeKey(kind: .spaceWindowCreated, id: 3))
    }

    test("IntakeEvent.key: 1508s merge into one frontmost item whatever the pid") {
        try expectEqual(IntakeEvent.window(.frontmostByMouse(pid: 10)).key, IntakeKey(kind: .frontmost, id: 0))
        try expectEqual(IntakeEvent.window(.frontmostByMouse(pid: nil)).key, IntakeKey(kind: .frontmost, id: 0))
    }

    test("IntakeEvent.key: process-wide events share one key each") {
        try expectEqual(IntakeEvent.window(.animationBegan).key, IntakeKey(kind: .animationBegan, id: 0))
        try expectEqual(IntakeEvent.spaces.key, IntakeKey(kind: .spaces, id: 0))
        try expectEqual(IntakeEvent.missionControlEntered.key, IntakeKey(kind: .missionControlEntered, id: 0))
    }

    test("IntakeEvent.key: events with nothing to do on main have no key") {
        try expectEqual(IntakeEvent.window(.ignored).key, nil)
        try expectEqual(IntakeEvent.window(.malformed).key, nil)
        try expectEqual(IntakeEvent.window(.titleChanged(wid: 1)).key, nil)
        try expectEqual(IntakeEvent.window(.spaceWindowDestroyed(wid: 1, spaceID: 2)).key, nil)
    }

    test("IntakeKind names are distinct") {
        let names = IntakeKind.allCases.map { $0.name }
        try expectEqual(Set(names).count, names.count)
    }
}

// SpacesCoalescer: one space switch posts 1401, activeSpaceDidChange and
// often 1325s for windows already on the new space. Every request made
// while a drain runs (a queued spaces item, a 1325 handler) collapses into
// one spaces pass at the end of that drain.
func registerSpacesCoalescerTests() {
    test("SpacesCoalescer: requests during a drain collapse into one pass at its end") {
        var c = SpacesCoalescer()
        c.begin()
        try expect(!c.request())
        try expect(!c.request())
        try expect(!c.request())
        try expect(c.end())
    }

    test("SpacesCoalescer: a drain with no request runs no pass") {
        var c = SpacesCoalescer()
        c.begin()
        try expect(!c.end())
    }

    test("SpacesCoalescer: the pass is consumed, the next drain starts clean") {
        var c = SpacesCoalescer()
        c.begin(); _ = c.request(); _ = c.end()
        c.begin()
        try expect(!c.end())
    }

    test("SpacesCoalescer: a request outside a drain asks the caller to post one") {
        var c = SpacesCoalescer()
        try expect(c.request())
    }

    test("SpacesCoalescer: a request after the drain ended is posted, not folded into the old pass") {
        var c = SpacesCoalescer()
        c.begin(); _ = c.end()
        try expect(c.request())
    }
}
