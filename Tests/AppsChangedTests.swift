import Foundation

/// Tests for `Bridge.appsDelta` — the pure diff that drives `sd.apps.changed`.
/// Only the adapter-specific parts are covered here (identity is bundleId, the
/// equality predicate compares active / hidden / name); the generic
/// added/removed walk is covered by ComputeDeltaTests.
func registerAppsChangedTests() {
    func app(_ bundleId: String, active: Bool = false, hidden: Bool = false, name: String? = nil) -> [String: Any] {
        return [
            "bundleId": bundleId,
            "name":     name ?? bundleId,
            "active":   active,
            "hidden":   hidden
        ]
    }

    test("removed: a quit app lands in `removed`") {
        let prev: [String: [String: Any]] = ["com.a": app("com.a"), "com.b": app("com.b")]
        let d = Bridge.appsDelta(snapshot: [app("com.a")], previous: prev)
        try expectEqual(d.removed.count, 1)
        try expectEqual(d.removed.first?["bundleId"] as? String, "com.b")
    }

    test("active flip lands in `changed` (app comes to front)") {
        let prev: [String: [String: Any]] = ["com.a": app("com.a", active: false)]
        let d = Bridge.appsDelta(snapshot: [app("com.a", active: true)], previous: prev)
        try expectEqual(d.changed.count, 1)
        try expectEqual(d.changed.first?["bundleId"] as? String, "com.a")
    }

    test("hidden flip lands in `changed`") {
        let prev: [String: [String: Any]] = ["com.a": app("com.a", hidden: false)]
        let d = Bridge.appsDelta(snapshot: [app("com.a", hidden: true)], previous: prev)
        try expectEqual(d.changed.count, 1)
    }

    test("name change lands in `changed` (localization switch)") {
        let prev: [String: [String: Any]] = ["com.a": app("com.a", name: "Old")]
        let d = Bridge.appsDelta(snapshot: [app("com.a", name: "New")], previous: prev)
        try expectEqual(d.changed.count, 1)
    }

    test("identical snapshot: nothing fires (regression guard against dict-key noise)") {
        let prev: [String: [String: Any]] = ["com.a": app("com.a", active: true, hidden: false, name: "A")]
        let d = Bridge.appsDelta(snapshot: [app("com.a", active: true, hidden: false, name: "A")], previous: prev)
        try expectEqual(d.changed.count + d.added.count + d.removed.count, 0)
    }

    test("fields outside active/hidden/name don't fire `changed`") {
        var before = app("com.a"); before["pid"] = 100; before["launchedAt"] = 1.0
        var after  = app("com.a"); after["pid"]  = 200; after["launchedAt"]  = 2.0
        let d = Bridge.appsDelta(snapshot: [after], previous: ["com.a": before])
        try expectEqual(d.changed.count + d.added.count + d.removed.count, 0)
    }

    test("row without bundleId is dropped (identity nil), not crashed") {
        let d = Bridge.appsDelta(snapshot: [["name": "no-bundle", "active": true]], previous: [:])
        try expectEqual(d.added.count, 0)
        try expectEqual(d.nowByBundle.count, 0)
    }

    test("duplicate bundleId is last-wins (WebKit helpers share a bundleId)") {
        // GPU + Networking helpers share their bundleId across every WKWebView.
        // Keying must accept last-wins, not crash on duplicate keys.
        let snapshot = [app("com.helper", active: false), app("com.helper", active: true)]
        let d = Bridge.appsDelta(snapshot: snapshot, previous: [:])
        try expectEqual(d.added.count, 1)
        try expectEqual(d.nowByBundle["com.helper"]?["active"] as? Bool, true)
    }

    test("mixed add+remove+change in one tick") {
        let prev: [String: [String: Any]] = [
            "com.a": app("com.a", active: false),   // will flip active
            "com.b": app("com.b"),                  // stays put
            "com.c": app("com.c")                   // quits
        ]
        let snapshot = [
            app("com.a", active: true),
            app("com.b"),
            app("com.d")                            // launches
        ]
        let d = Bridge.appsDelta(snapshot: snapshot, previous: prev)
        try expectEqual(d.added.first?["bundleId"] as? String, "com.d")
        try expectEqual(d.removed.first?["bundleId"] as? String, "com.c")
        try expectEqual(d.changed.first?["bundleId"] as? String, "com.a")
    }
}
