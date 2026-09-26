import Foundation

/// Tests for `Bridge.displaysDelta` — the pure diff that drives
/// `sd.displays.changed`. Only the adapter-specific parts are covered here
/// (identity is displayID, the equality predicate compares brightness +
/// frame); the generic added/removed walk is covered by ComputeDeltaTests.
func registerDisplaysChangedTests() {
    func disp(_ id: Int, brightness: Float? = 0.5, frame: (Int, Int, Int, Int) = (0, 0, 1512, 982)) -> [String: Any] {
        return [
            "displayID":  id,
            "name":       "Display \(id)",
            "brightness": brightness as Any? ?? NSNull(),
            "frame":      ["x": frame.0, "y": frame.1, "w": frame.2, "h": frame.3]
        ]
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

    test("unreadable brightness: nil → nil is quiet, nil → value is `changed`") {
        // External displays without DDC read support report nil brightness
        // on every poll; that must not fire 'changed' each tick. A read that
        // starts succeeding is a real transition.
        let prev: [Int: [String: Any]] = [1: disp(1, brightness: nil)]
        let quiet = Bridge.displaysDelta(snapshot: [disp(1, brightness: nil)], previous: prev)
        try expectEqual(quiet.changed.count, 0)
        let readable = Bridge.displaysDelta(snapshot: [disp(1, brightness: 0.5)], previous: prev)
        try expectEqual(readable.changed.count, 1)
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
