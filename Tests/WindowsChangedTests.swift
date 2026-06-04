import Foundation

/// Tests for `Bridge.windowsDelta` — the pure diff between two window
/// snapshots that drives `sd.windows.changed`. Stacks pay diff-size
/// instead of full-list-size; we pin the comparison rules here so a
/// title flicker doesn't fire `added` and a frame nudge doesn't
/// silently disappear.
func registerWindowsChangedTests() {
    // Helper: build a synthetic window dict in the shape Windows.all() returns.
    func win(_ id: Int, app: String = "App", title: String = "Title", frame: (Int, Int, Int, Int) = (0, 0, 100, 100)) -> [String: Any] {
        return [
            "id":    id,
            "app":   app,
            "title": title,
            "frame": ["x": frame.0, "y": frame.1, "w": frame.2, "h": frame.3]
        ]
    }

    test("empty → empty: no changes, no nowByID entries") {
        let d = Bridge.windowsDelta(snapshot: [], previous: [:])
        try expectEqual(d.added.count, 0)
        try expectEqual(d.removed.count, 0)
        try expectEqual(d.changed.count, 0)
        try expectEqual(d.nowByID.count, 0)
    }

    test("first snapshot from empty previous: all entries are added") {
        let d = Bridge.windowsDelta(snapshot: [win(10), win(11)], previous: [:])
        try expectEqual(d.added.count, 2)
        try expectEqual(d.removed.count, 0)
        try expectEqual(d.changed.count, 0)
        try expectEqual(d.nowByID.count, 2)
    }

    test("removed: previous id missing from snapshot lands in `removed`") {
        let prev: [Int: [String: Any]] = [10: win(10), 11: win(11)]
        let d = Bridge.windowsDelta(snapshot: [win(10)], previous: prev)
        try expectEqual(d.added.count, 0)
        try expectEqual(d.removed.count, 1)
        try expectEqual(d.removed.first?["id"] as? Int, 11)
        try expectEqual(d.changed.count, 0)
    }

    test("title change lands in `changed` (consumers like windowscape track rename)") {
        let prev: [Int: [String: Any]] = [10: win(10, title: "Old")]
        let d = Bridge.windowsDelta(snapshot: [win(10, title: "New")], previous: prev)
        try expectEqual(d.changed.count, 1)
        try expectEqual(d.changed.first?["id"] as? Int, 10)
        try expectEqual(d.added.count, 0)
        try expectEqual(d.removed.count, 0)
    }

    test("frame change lands in `changed`") {
        let prev: [Int: [String: Any]] = [10: win(10, frame: (0, 0, 100, 100))]
        let d = Bridge.windowsDelta(snapshot: [win(10, frame: (50, 50, 100, 100))], previous: prev)
        try expectEqual(d.changed.count, 1)
        try expectEqual(d.changed.first?["id"] as? Int, 10)
    }

    test("identical snapshot: nothing fires (regression guard against jsonify-key-order noise)") {
        // The whole reason we compare specific fields instead of jsonify
        // strings: Swift dict insertion order is non-deterministic, and a
        // jsonify-comparison would fire `changed` on every poll for free.
        let prev: [Int: [String: Any]] = [10: win(10, app: "App", title: "T", frame: (1, 2, 3, 4))]
        let d = Bridge.windowsDelta(snapshot: [win(10, app: "App", title: "T", frame: (1, 2, 3, 4))], previous: prev)
        try expectEqual(d.changed.count, 0)
        try expectEqual(d.added.count, 0)
        try expectEqual(d.removed.count, 0)
    }

    test("mixed add+remove+change in one tick") {
        let prev: [Int: [String: Any]] = [
            10: win(10, title: "Stable"),
            11: win(11, title: "Renaming"),
            12: win(12)  // will be removed
        ]
        let snapshot = [
            win(10, title: "Stable"),
            win(11, title: "Renamed"),
            win(13)  // newly added
        ]
        let d = Bridge.windowsDelta(snapshot: snapshot, previous: prev)
        try expectEqual(d.added.first?["id"] as? Int, 13)
        try expectEqual(d.removed.first?["id"] as? Int, 12)
        try expectEqual(d.changed.first?["id"] as? Int, 11)
    }

    test("nowByID returned by windowsDelta replaces the caller's cache without re-walk") {
        // Avoids the caller building the dictionary a second time — the
        // delta already walked the snapshot once.
        let d = Bridge.windowsDelta(snapshot: [win(10), win(20)], previous: [:])
        try expectEqual(d.nowByID.count, 2)
        try expectEqual(d.nowByID[10]?["id"] as? Int, 10)
        try expectEqual(d.nowByID[20]?["id"] as? Int, 20)
    }
}
