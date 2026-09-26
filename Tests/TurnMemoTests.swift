import Foundation

// Tests for `TurnMemo` in `Sources/BridgeChannels.swift` — the per-turn
// cache that lets every stack's workspace push share one Windows.all() /
// Windows.focused() / jsonify instead of recomputing them per stack.

func registerTurnMemoTests() {
    test("TurnMemo computes once within a turn") {
        var memo = TurnMemo<Int>()
        var calls = 0
        let a = memo.value(turn: 1) { calls += 1; return 42 }
        let b = memo.value(turn: 1) { calls += 1; return 99 }
        try expectEqual(a, 42)
        try expectEqual(b, 42)
        try expectEqual(calls, 1)
    }

    test("TurnMemo recomputes on a new turn") {
        var memo = TurnMemo<Int>()
        var calls = 0
        _ = memo.value(turn: 1) { calls += 1; return 1 }
        let fresh = memo.value(turn: 2) { calls += 1; return 2 }
        try expectEqual(fresh, 2)
        try expectEqual(calls, 2)
    }

    test("TurnMemo caches nil-carrying values too") {
        var memo = TurnMemo<String?>()
        var calls = 0
        _ = memo.value(turn: 5) { calls += 1; return nil }
        let again = memo.value(turn: 5) { calls += 1; return "late" }
        try expect(again == nil)
        try expectEqual(calls, 1)
    }

    test("TurnMemo serves a seeded value for its turn without computing") {
        var memo = TurnMemo<Int>()
        var calls = 0
        memo.seed(turn: 3, value: 7)
        let v = memo.value(turn: 3) { calls += 1; return 99 }
        try expectEqual(v, 7)
        try expectEqual(calls, 0)
    }

    test("TurnMemo recomputes after a seeded turn ends") {
        var memo = TurnMemo<Int>()
        memo.seed(turn: 3, value: 7)
        let v = memo.value(turn: 4) { 8 }
        try expectEqual(v, 8)
    }
}
