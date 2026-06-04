import Foundation

/// Tests for the generic `Bridge.computeDelta` helper that backs
/// `windowsDelta`, `displaysDelta`, and `menubarDelta`. These pin the
/// generic shape so future deltas (any [[String: Any]] snapshot with a
/// derivable identity + equality) can reuse the same primitive without
/// re-implementing the added/removed/changed walk.
///
/// The three existing adapter tests pin the per-channel field semantics
/// (which keys constitute identity, which fields gate `changed`). This
/// suite pins the *generic* contract using a synthetic id/value shape so
/// regressions in the shared loop surface here independently of any
/// channel-specific shape changes.
func registerComputeDeltaTests() {
    // Synthetic shape: { "id": Int, "value": Int }. Identity = id; equality
    // = value. Deliberately unrelated to windows/displays/menubar so the
    // adapters can drift without dragging this suite with them.
    func node(_ id: Int, value: Int = 0) -> [String: Any] {
        return ["id": id, "value": value]
    }
    func ident(_ item: [String: Any]) -> Int? { item["id"] as? Int }
    func eq(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        (a["value"] as? Int) == (b["value"] as? Int)
    }

    test("computeDelta: empty → empty produces no entries") {
        let d = Bridge.computeDelta(snapshot: [], previous: [:] as [Int: [String: Any]],
                                    identity: ident, equal: eq)
        try expectEqual(d.added.count + d.removed.count + d.changed.count, 0)
        try expectEqual(d.nowByKey.count, 0)
    }

    test("computeDelta: first snapshot from empty previous routes everything to `added`") {
        let d = Bridge.computeDelta(snapshot: [node(1), node(2)], previous: [:] as [Int: [String: Any]],
                                    identity: ident, equal: eq)
        try expectEqual(d.added.count, 2)
        try expectEqual(d.removed.count, 0)
        try expectEqual(d.changed.count, 0)
        try expectEqual(d.nowByKey.count, 2)
    }

    test("computeDelta: previous key missing from snapshot routes to `removed`") {
        let prev: [Int: [String: Any]] = [1: node(1), 2: node(2)]
        let d = Bridge.computeDelta(snapshot: [node(1)], previous: prev,
                                    identity: ident, equal: eq)
        try expectEqual(d.removed.count, 1)
        try expectEqual(d.removed.first?["id"] as? Int, 2)
        try expectEqual(d.added.count, 0)
        try expectEqual(d.changed.count, 0)
    }

    test("computeDelta: equal-returns-false routes to `changed` (not added)") {
        let prev: [Int: [String: Any]] = [1: node(1, value: 10)]
        let d = Bridge.computeDelta(snapshot: [node(1, value: 20)], previous: prev,
                                    identity: ident, equal: eq)
        try expectEqual(d.changed.count, 1)
        try expectEqual(d.changed.first?["id"] as? Int, 1)
        try expectEqual(d.added.count, 0)
        try expectEqual(d.removed.count, 0)
    }

    test("computeDelta: equal-returns-true is a no-op (regression guard for stable snapshots)") {
        let prev: [Int: [String: Any]] = [1: node(1, value: 10)]
        let d = Bridge.computeDelta(snapshot: [node(1, value: 10)], previous: prev,
                                    identity: ident, equal: eq)
        try expectEqual(d.added.count + d.removed.count + d.changed.count, 0)
        try expectEqual(d.nowByKey[1]?["value"] as? Int, 10)
    }

    test("computeDelta: identity returning nil drops the entry (no crash, no add)") {
        // Defensive contract — windowsDelta drops snapshot rows missing
        // `id`; the generic loop must behave the same way for any adapter
        // whose identity closure can fail.
        let snapshot: [[String: Any]] = [node(1), ["value": 7] /* no id */]
        let d = Bridge.computeDelta(snapshot: snapshot, previous: [:] as [Int: [String: Any]],
                                    identity: ident, equal: eq)
        try expectEqual(d.added.count, 1)
        try expectEqual(d.nowByKey.count, 1)
        try expectEqual(d.nowByKey[1]?["id"] as? Int, 1)
    }

    test("computeDelta: works with String keys (proves the generic is truly key-agnostic)") {
        // menubarDelta keys on "<owner>|<title>"; this test confirms the
        // generic loop doesn't accidentally specialize on Int.
        func sIdent(_ item: [String: Any]) -> String? { item["k"] as? String }
        func sEq(_ a: [String: Any], _ b: [String: Any]) -> Bool {
            (a["v"] as? Int) == (b["v"] as? Int)
        }
        let prev: [String: [String: Any]] = [
            "a": ["k": "a", "v": 1],
            "b": ["k": "b", "v": 2]
        ]
        let snap: [[String: Any]] = [
            ["k": "a", "v": 1],   // unchanged
            ["k": "b", "v": 99],  // changed
            ["k": "c", "v": 3]    // added
            // "b" stays, but value differs; nothing maps to "removed" here
            // — let's also drop one to exercise removal.
        ]
        let d = Bridge.computeDelta(snapshot: snap, previous: prev,
                                    identity: sIdent, equal: sEq)
        try expectEqual(d.added.first?["k"] as? String, "c")
        try expectEqual(d.changed.first?["k"] as? String, "b")
        try expectEqual(d.removed.count, 0)
        try expectEqual(d.nowByKey.count, 3)
    }
}
