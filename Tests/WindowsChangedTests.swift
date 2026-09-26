import Foundation

/// Tests for `Bridge.windowsDelta` — the pure diff between two window
/// snapshots that drives `sd.windows.changed`. Generic added/removed routing
/// is covered by ComputeDeltaTests; these pin the window-specific rules:
/// identity is `id`, and only title and frame transitions count as changed.
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
        try expectEqual(d.added.map { $0["id"] as? Int }, [13])
        try expectEqual(d.removed.map { $0["id"] as? Int }, [12])
        try expectEqual(d.changed.map { $0["id"] as? Int }, [11])
    }

    test("fields other than title and frame don't fire `changed`") {
        var before = win(10)
        before["onscreen"] = true
        var after = win(10, app: "Renamed App")
        after["onscreen"] = false
        let d = Bridge.windowsDelta(snapshot: [after], previous: [10: before])
        try expectEqual(d.changed.count, 0)
        try expectEqual(d.nowByID[10]?["app"] as? String, "Renamed App",
                        "the cache still takes the newest row")
    }

    test("nowByID keys every snapshot row by its window id") {
        let d = Bridge.windowsDelta(snapshot: [win(10), win(20)], previous: [:])
        try expectEqual(d.nowByID.count, 2)
        try expectEqual(d.nowByID[10]?["id"] as? Int, 10)
        try expectEqual(d.nowByID[20]?["id"] as? Int, 20)
    }
}
