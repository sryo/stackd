import Foundation

// LatestWinsQueue — the insertion-ordered, replace-in-place map under the
// window-server intake queue and the motion write mailbox.
func registerLatestWinsQueueTests() {
    typealias Queue = LatestWinsQueue<String, Int>
    let replace: (Int, Int) -> Int = { _, new in new }

    test("LatestWinsQueue: values come out in first-arrival order") {
        var q = Queue()
        _ = q.offer("b", 1, merge: replace)
        _ = q.offer("a", 2, merge: replace)
        _ = q.offer("c", 3, merge: replace)
        try expectEqual(q.take().map { $0.key }, ["b", "a", "c"])
    }

    test("LatestWinsQueue: a repeated key replaces its value in place") {
        var q = Queue()
        _ = q.offer("a", 1, merge: replace)
        _ = q.offer("b", 2, merge: replace)
        _ = q.offer("a", 3, merge: replace)
        let batch = q.take()
        try expectEqual(batch.map { $0.key }, ["a", "b"], "the repeat keeps its original position")
        try expectEqual(batch.map { $0.value }, [3, 2])
    }

    test("LatestWinsQueue: offer reports whether the key was new") {
        var q = Queue()
        try expect(q.offer("a", 1, merge: replace))
        try expect(!q.offer("a", 2, merge: replace))
        try expect(q.offer("b", 3, merge: replace))
    }

    test("LatestWinsQueue: merge sees the waiting value first and the offered one second") {
        var q = Queue()
        _ = q.offer("a", 1, merge: { old, new in old * 10 + new })
        _ = q.offer("a", 2, merge: { old, new in old * 10 + new })
        _ = q.offer("a", 3, merge: { old, new in old * 10 + new })
        try expectEqual(q.take().map { $0.value }, [123])
    }

    test("LatestWinsQueue: merge runs only for a key already waiting") {
        var q = Queue()
        var merges = 0
        let counting: (Int, Int) -> Int = { _, new in merges += 1; return new }
        _ = q.offer("a", 1, merge: counting)
        _ = q.offer("b", 2, merge: counting)
        try expectEqual(merges, 0)
        _ = q.offer("a", 3, merge: counting)
        try expectEqual(merges, 1)
    }

    test("LatestWinsQueue: contains and count track what waits") {
        var q = Queue()
        try expect(q.isEmpty)
        try expect(!q.contains("a"))
        _ = q.offer("a", 1, merge: replace)
        _ = q.offer("a", 2, merge: replace)
        _ = q.offer("b", 3, merge: replace)
        try expect(q.contains("a") && q.contains("b") && !q.contains("c"))
        try expectEqual(q.count, 2)
        try expect(!q.isEmpty)
    }

    test("LatestWinsQueue: take empties the queue, and the next offer starts a fresh order") {
        var q = Queue()
        _ = q.offer("a", 1, merge: replace)
        _ = q.offer("b", 2, merge: replace)
        _ = q.take()
        try expect(q.isEmpty)
        try expect(!q.contains("a"))
        try expectEqual(q.take().count, 0)
        try expect(q.offer("b", 3, merge: replace), "a taken key is new again")
        _ = q.offer("a", 4, merge: replace)
        try expectEqual(q.take().map { $0.key }, ["b", "a"])
    }
}
