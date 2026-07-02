import Foundation
import CoreGraphics

// FrameBangCoalescer — pure decision core for moved/resized bang dispatch.
// Leading edge fires immediately (drag brackets need a prompt wake-up);
// events inside the 80ms quiet window are held last-write-wins and the
// trailing tick delivers the final payload. Keyed per (window, kind) so a
// drag's move stream can't starve a resize bang and windows don't couple.
func registerFrameCoalescerTests() {
    func key(_ wid: CGWindowID, _ kind: FrameBangCoalescer.Kind) -> FrameBangCoalescer.Key {
        FrameBangCoalescer.Key(windowID: wid, kind: kind)
    }

    test("first event emits immediately (leading edge)") {
        var c = FrameBangCoalescer()
        try expectEqual(c.onEvent(key(1, .moved), now: 0), .emit)
    }

    test("events inside the quiet window hold; trailing tick emits the held payload") {
        var c = FrameBangCoalescer()
        _ = c.onEvent(key(1, .moved), now: 0)
        try expectEqual(c.onEvent(key(1, .moved), now: 0.02), .hold)
        try expectEqual(c.onEvent(key(1, .moved), now: 0.05), .hold,
                        "every in-window event replaces the held payload")
        try expectEqual(c.onTick(key(1, .moved), now: 0.085), .emitHeld)
    }

    test("trailing emit re-arms the window — a burst never fires faster than the quiet cadence") {
        var c = FrameBangCoalescer()
        _ = c.onEvent(key(1, .moved), now: 0)
        _ = c.onEvent(key(1, .moved), now: 0.03)
        _ = c.onTick(key(1, .moved), now: 0.085) // .emitHeld, re-armed
        try expectEqual(c.onEvent(key(1, .moved), now: 0.1), .hold,
                        "event right after a trailing emit must hold, not double-fire")
        try expectEqual(c.onTick(key(1, .moved), now: 0.17), .emitHeld)
    }

    test("quiet tick closes the gate; the next event is a fresh leading edge") {
        var c = FrameBangCoalescer()
        _ = c.onEvent(key(1, .moved), now: 0)
        try expectEqual(c.onTick(key(1, .moved), now: 0.085), .close)
        try expectEqual(c.onEvent(key(1, .moved), now: 0.2), .emit)
    }

    test("keys are independent per window and per kind") {
        var c = FrameBangCoalescer()
        _ = c.onEvent(key(1, .moved), now: 0)
        try expectEqual(c.onEvent(key(1, .resized), now: 0.01), .emit,
                        "a move stream must not throttle resize bangs")
        try expectEqual(c.onEvent(key(2, .moved), now: 0.01), .emit,
                        "windows must not couple")
    }

    test("a stale tick does not close a re-armed gate") {
        var c = FrameBangCoalescer()
        _ = c.onEvent(key(1, .moved), now: 0)
        // Gate expired un-fired (timer jitter); the next event re-arms as a
        // fresh leading edge, which schedules its own tick.
        try expectEqual(c.onEvent(key(1, .moved), now: 0.09), .emit)
        // The ORIGINAL tick finally fires, mid-window of the new gate: it
        // must not close it.
        try expectEqual(c.onTick(key(1, .moved), now: 0.095), .close)
        try expectEqual(c.onEvent(key(1, .moved), now: 0.1), .hold,
                        "gate must still be armed after the stale tick")
        try expectEqual(c.onTick(key(1, .moved), now: 0.18), .emitHeld)
    }

    test("purge drops both kinds for the destroyed window only") {
        var c = FrameBangCoalescer()
        _ = c.onEvent(key(1, .moved), now: 0)
        _ = c.onEvent(key(1, .resized), now: 0)
        _ = c.onEvent(key(2, .moved), now: 0)
        _ = c.onEvent(key(1, .moved), now: 0.01)   // held
        c.purge(windowID: 1)
        try expectEqual(c.onEvent(key(2, .moved), now: 0.02), .hold,
                        "other windows keep their gates")
        try expectEqual(c.onTick(key(1, .moved), now: 0.085), .close,
                        "held payload for a destroyed window must not deliver")
        try expectEqual(c.onEvent(key(1, .moved), now: 0.09), .emit,
                        "purged window starts fresh")
    }
}
