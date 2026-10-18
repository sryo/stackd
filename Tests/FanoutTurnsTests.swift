import Foundation

// `FanoutTurns` in `Sources/BridgeChannels.swift` — the turn numbers that let
// every stack's workspace push share one window-list read. One focus change
// fans out to a dozen stacks back to back; the first read costs tens of
// milliseconds (Windows.all()), so a turn must not age out because that read
// was slow, or every following stack recomputes it.

func registerFanoutTurnsTests() {
    test("FanoutTurns: reads made back to back share a turn") {
        var turns = FanoutTurns(maxIdle: 0.010)
        let a = turns.current(now: 0)
        let b = turns.current(now: 0.001)
        try expectEqual(a.turn, b.turn)
        try expect(a.opened, "the first read opens the turn")
        try expect(!b.opened, "a later read joins it")
    }

    test("FanoutTurns: a slow read does not age out the turn it served") {
        var turns = FanoutTurns(maxIdle: 0.010)
        let first = turns.current(now: 0)
        // The read took 40 ms; the next stack asks right after it finished.
        turns.touch(now: 0.040)
        let next = turns.current(now: 0.0401)
        try expectEqual(next.turn, first.turn, "the second stack must reuse the first stack's snapshot")
        try expect(!next.opened)
    }

    test("FanoutTurns: a gap longer than the idle limit starts a new turn") {
        var turns = FanoutTurns(maxIdle: 0.010)
        let first = turns.current(now: 0)
        let later = turns.current(now: 0.050)
        try expect(later.turn != first.turn, "a stale snapshot must not serve a later event")
    }

    test("FanoutTurns: closing the turn makes the next read start a fresh one") {
        var turns = FanoutTurns(maxIdle: 0.010)
        let first = turns.current(now: 0)
        turns.close()
        let next = turns.current(now: 0.001)
        try expect(next.turn != first.turn)
        try expect(next.opened, "a read after the close reopens a turn")
    }

    test("FanoutTurns: advancing drops the open turn without reading") {
        var turns = FanoutTurns(maxIdle: 0.010)
        let first = turns.current(now: 0)
        turns.advance()
        let next = turns.current(now: 0.001)
        try expect(next.turn != first.turn)
        try expect(next.opened)
    }
}
