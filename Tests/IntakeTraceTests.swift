import Foundation

// Tests for the in-daemon intake trace (Sources/DataSources/IntakeTrace.swift):
// `TraceRing` (bounded, overwrites oldest), `IntakeTracer` (per drained
// item: queue wait and handler time, and no clock reads at all while
// disabled) and `IntakeTraceDump` (the JSON the bench collects).

func registerIntakeTraceTests() {
    // MARK: TraceRing

    test("TraceRing: holds up to capacity, oldest first") {
        var r = TraceRing<Int>(capacity: 3)
        r.append(1); r.append(2)
        try expectEqual(r.elements, [1, 2])
        r.append(3)
        try expectEqual(r.elements, [1, 2, 3])
        try expectEqual(r.overwritten, 0)
    }

    test("TraceRing: wraps around, overwriting the oldest") {
        var r = TraceRing<Int>(capacity: 3)
        for i in 1...7 { r.append(i) }
        try expectEqual(r.elements, [5, 6, 7])
        try expectEqual(r.overwritten, 4)
        try expectEqual(r.count, 3)
    }

    test("TraceRing: capacity below 1 is clamped to 1") {
        var r = TraceRing<Int>(capacity: 0)
        r.append(1); r.append(2)
        try expectEqual(r.elements, [2])
    }

    test("TraceRing: starts empty") {
        let r = TraceRing<Int>(capacity: 4)
        try expectEqual(r.elements, [])
        try expectEqual(r.count, 0)
    }

    // MARK: IntakeTracer

    test("IntakeTracer: disabled reads no clock and records nothing") {
        var reads = 0
        let t = IntakeTracer(enabled: false, capacity: 8, clock: { reads += 1; return 0 })
        try expectEqual(t.stamp(), nil)
        var ran = false
        t.measure(.frame, enqueued: nil, merged: 1) { ran = true }
        t.measure(.frame, enqueued: 5, merged: 1) { ran = true }
        try expect(ran)
        try expectEqual(reads, 0)
        try expectEqual(t.ring.count, 0)
    }

    test("IntakeTracer: records queue wait and handler time in µs") {
        var ticks: [UInt64] = [10_000, 13_500]   // handler start, handler end (ns)
        let t = IntakeTracer(enabled: true, capacity: 8, clock: { ticks.removeFirst() })
        t.measure(.reordered, enqueued: 4_000, merged: 3) {}
        let rec = t.ring.elements
        try expectEqual(rec.count, 1)
        try expectEqual(rec[0].kind, .reordered)
        try expectEqual(rec[0].enqueuedNs, 4_000)
        try expectEqual(rec[0].queueUs, 6.0)
        try expectEqual(rec[0].handlerUs, 3.5)
        try expectEqual(rec[0].merged, 3)
    }

    test("IntakeTracer: an item without an enqueue time runs untimed") {
        var reads = 0
        let t = IntakeTracer(enabled: true, capacity: 8, clock: { reads += 1; return 1 })
        var ran = false
        t.measure(.spaces, enqueued: nil, merged: 1) { ran = true }
        try expect(ran)
        try expectEqual(reads, 0)
        try expectEqual(t.ring.count, 0)
    }

    test("IntakeTracer: enabled stamp reads the clock") {
        let t = IntakeTracer(enabled: true, capacity: 8, clock: { 42 })
        try expectEqual(t.stamp(), 42)
    }

    test("IntakeTracer: a clock that steps back clamps waits to zero") {
        var ticks: [UInt64] = [100, 50]
        let t = IntakeTracer(enabled: true, capacity: 8, clock: { ticks.removeFirst() })
        t.measure(.frame, enqueued: 500, merged: 1) {}
        try expectEqual(t.ring.elements[0].queueUs, 0)
        try expectEqual(t.ring.elements[0].handlerUs, 0)
    }

    test("IntakeTracer: the ring bounds the records kept") {
        var clock: UInt64 = 0
        let t = IntakeTracer(enabled: true, capacity: 2, clock: { clock += 1; return clock })
        for _ in 0..<5 { t.measure(.frame, enqueued: 0, merged: 1) {} }
        try expectEqual(t.ring.count, 2)
        try expectEqual(t.ring.overwritten, 3)
    }

    test("IntakeTracer.enabledFromEnv: on only for STACKD_TRACE=1") {
        try expect(IntakeTracer.enabledFromEnv(["STACKD_TRACE": "1"]))
        try expect(!IntakeTracer.enabledFromEnv([:]))
        try expect(!IntakeTracer.enabledFromEnv(["STACKD_TRACE": "0"]))
    }

    // MARK: IntakeTraceDump

    test("IntakeTraceDump: JSON carries the records and the overwrite count") {
        var ticks: [UInt64] = [2_000, 3_000]
        let t = IntakeTracer(enabled: true, capacity: 4, clock: { ticks.removeFirst() })
        t.measure(.frame, enqueued: 1_000, merged: 2) {}
        let data = IntakeTraceDump.json(t.ring, pid: 77)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try expectEqual(obj?["pid"] as? Int, 77)
        try expectEqual(obj?["overwritten"] as? Int, 0)
        try expectEqual(obj?["capacity"] as? Int, 4)
        let recs = obj?["records"] as? [[String: Any]] ?? []
        try expectEqual(recs.count, 1)
        try expectEqual(recs[0]["kind"] as? String, "frame")
        try expectEqual(recs[0]["queue_us"] as? Double, 1.0)
        try expectEqual(recs[0]["handler_us"] as? Double, 1.0)
        try expectEqual(recs[0]["merged"] as? Int, 2)
        try expectEqual(recs[0]["t_us"] as? Double, 1.0)
    }

    test("IntakeTraceDump.path: STACKD_TRACE_PATH overrides the default") {
        try expectEqual(IntakeTraceDump.path(env: ["STACKD_TRACE_PATH": "/tmp/x.json"], home: "/Users/u"),
                        "/tmp/x.json")
        try expectEqual(IntakeTraceDump.path(env: [:], home: "/Users/u"),
                        "/Users/u/Library/Logs/stackd-trace.json")
    }
}
