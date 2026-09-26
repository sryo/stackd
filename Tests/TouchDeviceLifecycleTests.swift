import Foundation

// Tests for the pure pieces of sd.touchdevice's multi-device lifecycle in
// Sources/DataSources/Input.swift: the refcon token that routes a
// MultitouchSupport callback to its registration, and the policy that turns
// sleep / wake / unlock / hot-plug / registration outcomes into teardown and
// (re-)registration actions.
func registerTouchDeviceLifecycleTests() {

    test("TouchDeviceRefcon: round-trips generation and slot") {
        for (gen, slot) in [(1, 0), (1, 7), (42, 3), (0xFFFF_FF, 255)] {
            let token = TouchDeviceRefcon.encode(generation: UInt(gen), slot: slot)
            try expect(token != nil, "encodable \(gen)/\(slot)")
            let d = TouchDeviceRefcon.decode(token)
            try expectEqual(d?.generation, UInt(gen))
            try expectEqual(d?.slot, slot)
        }
    }

    test("TouchDeviceRefcon: generation 0, oversized generations and out-of-range slots don't encode") {
        try expect(TouchDeviceRefcon.encode(generation: 0, slot: 0) == nil, "gen 0 is the null pointer")
        try expect(TouchDeviceRefcon.encode(generation: 1, slot: 256) == nil, "slot must fit a byte")
        try expect(TouchDeviceRefcon.encode(generation: 1, slot: -1) == nil, "negative slot")
        try expect(TouchDeviceRefcon.encode(generation: UInt.max, slot: 0) == nil,
                   "a generation that would lose bits to the slot byte")
        try expect(TouchDeviceRefcon.decode(nil) == nil, "nil refcon")
    }

    test("TouchDeviceLifecycle: sleep tears down and cancels a pending register") {
        var lc = TouchDeviceLifecycle()
        try expectEqual(lc.handle(.topologyChanged), [.register(after: 1.0)])
        try expectEqual(lc.handle(.sleep), [.cancelPending, .teardown])
    }

    test("TouchDeviceLifecycle: wake and unlock re-register after the settle delay") {
        var lc = TouchDeviceLifecycle()
        _ = lc.handle(.sleep)
        try expectEqual(lc.handle(.wake), [.register(after: 1.0)])
        try expectEqual(lc.handle(.unlock), [.register(after: 1.0)])
    }

    test("TouchDeviceLifecycle: hot-plug while asleep waits for wake") {
        var lc = TouchDeviceLifecycle()
        _ = lc.handle(.sleep)
        try expectEqual(lc.handle(.topologyChanged), [])
        try expectEqual(lc.handle(.wake), [.register(after: 1.0)])
    }

    test("TouchDeviceLifecycle: a failed or empty registration retries with backoff, then stops") {
        var lc = TouchDeviceLifecycle(retryDelays: [1, 2, 4])
        try expectEqual(lc.handle(.registered(count: 0)), [.register(after: 1)])
        try expectEqual(lc.handle(.registered(count: 0)), [.register(after: 2)])
        try expectEqual(lc.handle(.registerFailed), [.register(after: 4)])
        try expectEqual(lc.handle(.registerFailed), [])
    }

    test("TouchDeviceLifecycle: success resets the backoff") {
        var lc = TouchDeviceLifecycle(retryDelays: [1, 2, 4])
        _ = lc.handle(.registerFailed)
        _ = lc.handle(.registerFailed)
        try expectEqual(lc.handle(.registered(count: 1)), [])
        try expectEqual(lc.handle(.registerFailed), [.register(after: 1)])
    }

    test("TouchDeviceLifecycle: a fresh signal restarts an exhausted backoff") {
        var lc = TouchDeviceLifecycle(retryDelays: [1])
        _ = lc.handle(.registerFailed)
        try expectEqual(lc.handle(.registerFailed), [])
        try expectEqual(lc.handle(.topologyChanged), [.register(after: 1.0)])
        try expectEqual(lc.handle(.registerFailed), [.register(after: 1)])
    }

    test("TouchDeviceLifecycle: registration outcomes while asleep schedule nothing") {
        var lc = TouchDeviceLifecycle()
        _ = lc.handle(.sleep)
        try expectEqual(lc.handle(.registerFailed), [])
        try expectEqual(lc.handle(.registered(count: 0)), [])
    }
}
