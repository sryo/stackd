import Foundation

// Tests for `TouchFrameMailbox` and `TouchFrame.payload` in
// Sources/DataSources/Input.swift — the policy between the MultitouchSupport
// callback thread and the main-thread drain that feeds sd.touchdevice.
// Everything here is pure: frames are built in memory and the clock is
// passed in.
func registerTouchFrameMailboxTests() {

    // MTPathStage raw values.
    let makeTouch: Int32 = 3, touching: Int32 = 4, breakTouch: Int32 = 5

    func contact(_ id: Int32, _ stage: Int32, x: Float = 0.5, y: Float = 0.5) -> TouchContact {
        TouchContact(id: id, stage: stage, x: x, y: y, vx: 0, vy: 0,
                     angle: 0, size: 0.25, pressure: 0, majorAxis: 8, minorAxis: 7)
    }
    func frame(_ n: Int, _ touches: [TouchContact], t: Double? = nil, device: UInt64 = 0) -> TouchFrame {
        TouchFrame(device: device, timestamp: t ?? Double(n) * 0.01, frame: n, touches: touches)
    }

    test("TouchFrameMailbox: the first frame of a touch asks for a drain") {
        let mb = TouchFrameMailbox()
        try expectEqual(mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0), true)
        try expectEqual(mb.take().map(\.frame), [1])
    }

    test("TouchFrameMailbox: one drain per burst until the drain takes") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0)
        try expectEqual(mb.offer(frame(2, [contact(1, touching, x: 0.6)]), now: 1.01), false)
        try expectEqual(mb.offer(frame(3, [contact(1, touching, x: 0.7)]), now: 1.02), false)
        _ = mb.take()
        try expectEqual(mb.offer(frame(4, [contact(1, touching, x: 0.8)]), now: 1.03), true)
    }

    test("TouchFrameMailbox: changed frames with the same finger count merge, newest wins") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0)
        _ = mb.offer(frame(2, [contact(1, touching, x: 0.6)]), now: 1.01)
        _ = mb.offer(frame(3, [contact(1, touching, x: 0.7)]), now: 1.02)
        _ = mb.offer(frame(4, [contact(1, touching, x: 0.8)]), now: 1.03)
        let out = mb.take()
        try expectEqual(out.map(\.frame), [1, 4])
        try expectEqual(out.last?.touches.first?.x, 0.8)
    }

    test("TouchFrameMailbox: a finger-count change is kept, not merged") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, touching), contact(2, touching)]), now: 1.0)
        _ = mb.take()
        _ = mb.offer(frame(2, [contact(1, touching, x: 0.6), contact(2, touching)]), now: 1.01)
        _ = mb.offer(frame(3, [contact(1, touching, x: 0.6), contact(2, touching), contact(3, touching)]), now: 1.02)
        _ = mb.offer(frame(4, [contact(1, touching, x: 0.7), contact(2, touching), contact(3, touching)]), now: 1.03)
        try expectEqual(mb.take().map(\.frame), [2, 3, 4])
    }

    test("TouchFrameMailbox: began/ended edges survive a burst") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0)
        _ = mb.offer(frame(2, [contact(1, touching, x: 0.6)]), now: 1.01)
        _ = mb.offer(frame(3, [contact(1, breakTouch, x: 0.6)]), now: 1.02)
        _ = mb.offer(frame(4, []), now: 1.03)
        try expectEqual(mb.take().map(\.frame), [1, 2, 3, 4])
    }

    test("TouchFrameMailbox: a changed frame never overwrites an edge frame") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0)
        _ = mb.offer(frame(2, [contact(1, touching, x: 0.6)]), now: 1.01)
        try expectEqual(mb.take().map(\.frame), [1, 2])
        _ = mb.offer(frame(3, [contact(1, touching, x: 0.7), contact(2, makeTouch)]), now: 1.02)
        _ = mb.offer(frame(4, [contact(1, touching, x: 0.8), contact(2, touching)]), now: 1.03)
        try expectEqual(mb.take().map(\.frame), [3, 4])
    }

    test("TouchFrameMailbox: empty frames while idle are dropped") {
        let mb = TouchFrameMailbox()
        try expectEqual(mb.offer(frame(1, []), now: 1.0), false)
        _ = mb.offer(frame(2, [contact(1, makeTouch)]), now: 1.01)
        _ = mb.offer(frame(3, []), now: 1.02)
        try expectEqual(mb.take().map(\.frame), [2, 3])
        try expectEqual(mb.offer(frame(4, []), now: 1.03), false)
        try expectEqual(mb.take().count, 0)
    }

    test("TouchFrameMailbox: sub-epsilon jitter of a resting finger is dropped") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, touching, x: 0.5)]), now: 1.0)
        _ = mb.take()
        try expectEqual(mb.offer(frame(2, [contact(1, touching, x: 0.5001)]), now: 1.01), false)
        try expectEqual(mb.take().count, 0)
        try expectEqual(mb.offer(frame(3, [contact(1, touching, x: 0.52)]), now: 1.02), true)
    }

    test("TouchFrameMailbox: pending never exceeds capacity and keeps the newest frame") {
        let mb = TouchFrameMailbox(capacity: 4)
        var n = 0
        for i in 0..<20 {
            n += 1
            let fingers = (i % 2 == 0) ? 1 : 2
            let touches = (0..<fingers).map { contact(Int32($0 + 1), touching, x: Float(i) * 0.01) }
            _ = mb.offer(frame(n, touches), now: 1.0 + Double(i) * 0.001)
        }
        let out = mb.take()
        try expect(out.count <= 4, "got \(out.count)")
        try expectEqual(out.last?.frame, n)
    }

    test("TouchFrameMailbox: watchdog idles when nothing is touching") {
        let mb = TouchFrameMailbox()
        try expectEqual(mb.checkWatchdog(now: 5.0), .idle)
        _ = mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0)
        _ = mb.offer(frame(2, []), now: 1.01)
        _ = mb.take()
        try expectEqual(mb.checkWatchdog(now: 5.0), .idle)
    }

    test("TouchFrameMailbox: watchdog re-arms at last frame + 120ms while frames are fresh") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)]), now: 1.0)
        _ = mb.take()
        try expectEqual(mb.checkWatchdog(now: 1.05), .rearm(at: 1.12))
    }

    test("TouchFrameMailbox: 120ms without frames synthesizes a release") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)], t: 50.0), now: 1.0)
        _ = mb.take()
        try expectEqual(mb.checkWatchdog(now: 1.13), .fired)
        let out = mb.take()
        try expectEqual(out.count, 1)
        try expectEqual(out[0].touches.count, 0)
        try expectEqual(out[0].synthetic, true)
        try expect(out[0].timestamp >= 50.12, "synthetic timestamp advances past the last frame")
        try expectEqual(mb.checkWatchdog(now: 2.0), .idle)
    }

    test("TouchFrameMailbox: touch resuming after a synthesized release starts over") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, touching)]), now: 1.0)
        _ = mb.take()
        _ = mb.checkWatchdog(now: 1.2)
        _ = mb.take()
        try expectEqual(mb.offer(frame(2, [contact(1, touching)]), now: 1.3), true)
        try expectEqual(mb.take().map(\.frame), [2])
    }

    test("TouchFrame.payload: keeps the sd.touchdevice shape") {
        let f = frame(7, [contact(3, touching, x: 0.25, y: 0.75)], t: 100.0)
        let p = TouchFrame.payload(f, uptimeNow: 100.004, epochMsNow: 1_700_000_000_000)
        try expectEqual(p["timestamp"] as? Double, 100.0)
        try expectEqual(p["frame"] as? Int, 7)
        let touches = p["touches"] as? [[String: Any]] ?? []
        try expectEqual(touches.count, 1)
        let t = touches[0]
        try expectEqual(Set(t.keys), ["identifier", "state", "x", "y", "vx", "vy", "angle",
                                      "size", "pressure", "majorAxis", "minorAxis"])
        try expectEqual(t["identifier"] as? Int, 3)
        try expectEqual(t["state"] as? String, "moved")
        try expectEqual(t["x"] as? Double, 0.25)
        try expectEqual(t["y"] as? Double, 0.75)
    }

    test("TouchFrame.payload: ages the frame from when the daemon received it") {
        // The device timestamp runs on MultitouchSupport's own clock, which
        // doesn't match systemUptime, so age comes from receivedAt.
        var f = frame(1, [contact(1, touching)], t: 867_460.0)
        f.receivedAt = 100.0
        let p = TouchFrame.payload(f, uptimeNow: 100.004, epochMsNow: 1234.5)
        try expectEqual(p["emittedAt"] as? Double, 1234.5)
        try expectEqual(p["timestamp"] as? Double, 867_460.0)
        let age = (p["ageMs"] as? Double) ?? -1
        try expect(abs(age - 4.0) < 0.001, "ageMs \(age)")
        var skewed = frame(1, [], t: 0)
        skewed.receivedAt = 200.0
        try expect(TouchFrame.payload(skewed, uptimeNow: 100.0, epochMsNow: 0)["ageMs"] is NSNull,
                   "a frame received in the future has no age")
        try expect(TouchFrame.payload(frame(1, [], t: 100.0), uptimeNow: 100.004, epochMsNow: 0)["ageMs"] is NSNull,
                   "a frame with no receive stamp has no age")
    }

    test("TouchFrame.payload: names the source device") {
        let f = frame(1, [contact(1, touching)], device: 0x1_0000_0abc)
        try expectEqual(TouchFrame.payload(f, uptimeNow: 1.0, epochMsNow: 0)["device"] as? UInt64, 0x1_0000_0abc)
    }

    test("TouchFrameMailbox: devices merge and time out independently") {
        let mb = TouchFrameMailbox()
        _ = mb.offer(frame(1, [contact(1, makeTouch)], device: 1), now: 1.0)
        _ = mb.offer(frame(1, [contact(1, makeTouch)], device: 2), now: 1.0)
        _ = mb.offer(frame(2, [contact(1, touching, x: 0.6)], device: 1), now: 1.01)
        _ = mb.offer(frame(2, [contact(1, touching, x: 0.6)], device: 2), now: 1.01)
        _ = mb.offer(frame(3, [contact(1, touching, x: 0.7)], device: 2), now: 1.02)
        let out = mb.take()
        try expectEqual(out.map { "\($0.device):\($0.frame)" }, ["1:1", "2:1", "1:2", "2:3"])
        _ = mb.offer(frame(4, [contact(1, touching, x: 0.8)], device: 2), now: 1.1)
        _ = mb.take()
        try expectEqual(mb.checkWatchdog(now: 1.13), .fired)
        let released = mb.take()
        try expectEqual(released.map(\.device), [1])
        try expectEqual(mb.checkWatchdog(now: 1.15), .rearm(at: 1.1 + 0.12))
    }

    test("TouchFrame.payload: marks synthesized releases") {
        var f = frame(1, [], t: 1.0)
        f.synthetic = true
        try expectEqual(TouchFrame.payload(f, uptimeNow: 1.0, epochMsNow: 0)["synthetic"] as? Bool, true)
        f.synthetic = false
        try expect(TouchFrame.payload(f, uptimeNow: 1.0, epochMsNow: 0)["synthetic"] == nil,
                   "real frames carry no synthetic key")
    }

    test("TouchFrame.stateName: MTPathStage maps to the documented vocabulary") {
        let expected: [(Int32, String)] = [
            (0, "cancelled"), (1, "began"), (2, "stationary"), (3, "began"),
            (4, "moved"), (5, "ended"), (6, "stationary"), (7, "lifted"), (42, "cancelled")
        ]
        for (raw, name) in expected {
            try expectEqual(TouchFrame.stateName(raw), name, "stage \(raw)")
        }
    }
}
