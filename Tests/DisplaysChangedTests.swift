import Foundation

/// Tests for `Bridge.displaysDelta` — the pure diff that drives
/// `sd.displays.changed`. Mirrors WindowsChangedTests in shape; the
/// equality predicate differs (brightness + frame vs title + frame).
func registerDisplaysChangedTests() {
    func disp(_ id: Int, brightness: Float? = 0.5, frame: (Int, Int, Int, Int) = (0, 0, 1512, 982)) -> [String: Any] {
        return [
            "displayID":  id,
            "name":       "Display \(id)",
            "brightness": brightness as Any? ?? NSNull(),
            "frame":      ["x": frame.0, "y": frame.1, "w": frame.2, "h": frame.3]
        ]
    }

    test("empty → empty: no changes, no nowByID entries") {
        let d = Bridge.displaysDelta(snapshot: [], previous: [:])
        try expectEqual(d.added.count + d.removed.count + d.changed.count, 0)
        try expectEqual(d.nowByID.count, 0)
    }

    test("first snapshot from empty previous: all entries are added") {
        let d = Bridge.displaysDelta(snapshot: [disp(1), disp(2)], previous: [:])
        try expectEqual(d.added.count, 2)
        try expectEqual(d.removed.count, 0)
        try expectEqual(d.changed.count, 0)
    }

    test("removed: external display unplug lands in `removed`") {
        let prev: [Int: [String: Any]] = [1: disp(1), 2: disp(2)]
        let d = Bridge.displaysDelta(snapshot: [disp(1)], previous: prev)
        try expectEqual(d.removed.count, 1)
        try expectEqual(d.removed.first?["displayID"] as? Int, 2)
    }

    test("brightness change lands in `changed` (live slider tracking)") {
        let prev: [Int: [String: Any]] = [1: disp(1, brightness: 0.5)]
        let d = Bridge.displaysDelta(snapshot: [disp(1, brightness: 0.75)], previous: prev)
        try expectEqual(d.changed.count, 1)
        try expectEqual(d.changed.first?["displayID"] as? Int, 1)
    }

    test("frame change lands in `changed` (resolution / arrangement)") {
        let prev: [Int: [String: Any]] = [1: disp(1, frame: (0, 0, 1512, 982))]
        let d = Bridge.displaysDelta(snapshot: [disp(1, frame: (1512, 0, 2560, 1440))], previous: prev)
        try expectEqual(d.changed.count, 1)
    }

    test("identical snapshot: nothing fires (regression guard against dict-key noise)") {
        let prev: [Int: [String: Any]] = [1: disp(1)]
        let d = Bridge.displaysDelta(snapshot: [disp(1)], previous: prev)
        try expectEqual(d.changed.count + d.added.count + d.removed.count, 0)
    }

    test("nil brightness on both sides isn't 'changed'") {
        // Built-in DDC failure mode: getBrightness returns nil. Both ticks
        // see nil → not a change. Guards against firing 'changed' on every
        // poll of an external display that doesn't implement the VCP read.
        let prev: [Int: [String: Any]] = [1: disp(1, brightness: nil)]
        let d = Bridge.displaysDelta(snapshot: [disp(1, brightness: nil)], previous: prev)
        try expectEqual(d.changed.count, 0)
    }

    test("mixed add+remove+change in one tick (display arrangement event)") {
        let prev: [Int: [String: Any]] = [
            1: disp(1),                                  // stays put
            2: disp(2, brightness: 0.5),                 // brightness ticks
            3: disp(3)                                   // gets unplugged
        ]
        let snapshot = [
            disp(1),
            disp(2, brightness: 0.75),
            disp(4)                                       // newly plugged in
        ]
        let d = Bridge.displaysDelta(snapshot: snapshot, previous: prev)
        try expectEqual(d.added.first?["displayID"] as? Int, 4)
        try expectEqual(d.removed.first?["displayID"] as? Int, 3)
        try expectEqual(d.changed.first?["displayID"] as? Int, 2)
    }
}
