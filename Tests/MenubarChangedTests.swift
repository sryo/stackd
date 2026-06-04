import Foundation

/// Tests for `Bridge.menubarDelta` — the pure diff that drives
/// `sd.menubar.changed`. Mirrors WindowsChangedTests / DisplaysChangedTests;
/// the identity is owner+title (menubar items have no stable id) and the
/// transition fields are x, width, hidden.
func registerMenubarChangedTests() {
    func item(owner: String, title: String, x: Double, width: Double = 22, hidden: Bool = false) -> [String: Any] {
        return [
            "owner":  owner,
            "title":  title,
            "x":      x,
            "width":  width,
            "hidden": hidden
        ]
    }

    test("empty → empty: no changes") {
        let d = Bridge.menubarDelta(snapshot: [], previous: [:])
        try expectEqual(d.added.count + d.removed.count + d.changed.count, 0)
        try expectEqual(d.nowByKey.count, 0)
    }

    test("first snapshot from empty previous: all entries added") {
        let snap = [item(owner: "Spotify", title: "Spotify", x: 100), item(owner: "Clock", title: "9:41", x: 200)]
        let d = Bridge.menubarDelta(snapshot: snap, previous: [:])
        try expectEqual(d.added.count, 2)
        try expectEqual(d.changed.count, 0)
    }

    test("removed: app quit, its menubar item lands in `removed`") {
        let prev: [String: [String: Any]] = [
            "Spotify|Spotify": item(owner: "Spotify", title: "Spotify", x: 100)
        ]
        let d = Bridge.menubarDelta(snapshot: [], previous: prev)
        try expectEqual(d.removed.count, 1)
        try expectEqual(d.removed.first?["owner"] as? String, "Spotify")
    }

    test("position change (x shift) lands in `changed`") {
        // Common shape: a new icon appears to the right of an existing
        // one, shifting the existing icon left. Only the existing icon
        // moved — its identity (owner|title) is unchanged.
        let prev: [String: [String: Any]] = [
            "Spotify|Spotify": item(owner: "Spotify", title: "Spotify", x: 100)
        ]
        let snap = [item(owner: "Spotify", title: "Spotify", x: 80)]
        let d = Bridge.menubarDelta(snapshot: snap, previous: prev)
        try expectEqual(d.changed.count, 1)
        try expectEqual(d.added.count, 0)
        try expectEqual(d.removed.count, 0)
    }

    test("hidden transition (notch overflow) lands in `changed`") {
        let prev: [String: [String: Any]] = [
            "Slack|Slack": item(owner: "Slack", title: "Slack", x: 50, hidden: false)
        ]
        let snap = [item(owner: "Slack", title: "Slack", x: 50, hidden: true)]
        let d = Bridge.menubarDelta(snapshot: snap, previous: prev)
        try expectEqual(d.changed.count, 1)
    }

    test("identical snapshot: nothing fires (poll-stable items don't churn)") {
        // The 2s poll cadence means this case fires every other tick on
        // a stable bar; the diff must shut up.
        let prev: [String: [String: Any]] = [
            "Clock|9:41": item(owner: "Clock", title: "9:41", x: 200)
        ]
        let snap = [item(owner: "Clock", title: "9:41", x: 200)]
        let d = Bridge.menubarDelta(snapshot: snap, previous: prev)
        try expectEqual(d.changed.count + d.added.count + d.removed.count, 0)
    }

    test("rename in place surfaces as paired removed + added (no stable id)") {
        // If Clock changes its title from "9:41" to "9:42" the identity
        // owner+title flips. Documents the tradeoff of having no stable
        // id — consumers see a remove+add, not a "changed". For clocks /
        // counters this is the right shape (the previous instance is gone).
        let prev: [String: [String: Any]] = [
            "Clock|9:41": item(owner: "Clock", title: "9:41", x: 200)
        ]
        let snap = [item(owner: "Clock", title: "9:42", x: 200)]
        let d = Bridge.menubarDelta(snapshot: snap, previous: prev)
        try expectEqual(d.added.count, 1)
        try expectEqual(d.removed.count, 1)
        try expectEqual(d.changed.count, 0)
    }

    test("mixed add+remove+change in one poll tick") {
        let prev: [String: [String: Any]] = [
            "Clock|9:41":      item(owner: "Clock",   title: "9:41",   x: 200),
            "Spotify|Spotify": item(owner: "Spotify", title: "Spotify", x: 100),
            "Old|Old":         item(owner: "Old",     title: "Old",     x: 50)
        ]
        let snap = [
            item(owner: "Clock",   title: "9:41",    x: 220),         // moved
            item(owner: "Spotify", title: "Spotify", x: 100),         // stable
            item(owner: "New",     title: "New",     x: 50)           // joined; Old gone
        ]
        let d = Bridge.menubarDelta(snapshot: snap, previous: prev)
        try expectEqual(d.changed.first?["owner"] as? String, "Clock")
        try expectEqual(d.added.first?["owner"] as? String, "New")
        try expectEqual(d.removed.first?["owner"] as? String, "Old")
    }
}
