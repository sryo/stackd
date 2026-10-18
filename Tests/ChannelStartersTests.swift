import Foundation

/// Guards the joint between `Channels.all` (the channel registry) and the
/// producers `Bridge.start(manifest:)` runs: a channel's own `feed`, or a
/// bespoke starter in `Bridge.customChannelStarters`. A replayable
/// `Channel(...)` with neither compiles fine and silently never replays —
/// `replayState()` finds no `lastState` because nothing produced it.
func registerChannelStartersTests() {
    // "app"/"windows" share startWorkspace (combined starter with
    // per-permission payload gating) — served, but not table rows.
    let workspaceServed: Set<String> = ["app", "windows"]

    test("every replayable channel has a producer") {
        let starterPerms = Set(Bridge.customChannelStarters.map { $0.permission })
            .union(workspaceServed)
        for ch in Channels.all where ch.replayable {
            try expect(
                ch.feed != nil || starterPerms.contains(ch.permission),
                "channel '\(ch.name)' (permission '\(ch.permission)') has no feed or starter — it will never produce or replay state")
        }
    }

    test("observer-fed channels are pinned in replay order") {
        // Dropping a feed silently stops a channel; adding one is a
        // same-commit update here.
        let fed = Channels.all.filter { $0.feed != nil }.map(\.name)
        try expectEqual(fed, [
            "battery", "mouse", "appearance", "inputLayout", "netThroughput",
            "audioOutput", "audioInput", "audioProcesses", "calendarChanged",
            "privacy", "pasteboard", "spaces", "caffeinate", "sensors",
            "location", "usb", "camera", "hostLoad", "touchdevice", "displayLink",
        ])
    }

    test("starter table permissions are all registered in Permissions.all") {
        for (permission, _) in Bridge.customChannelStarters {
            try expect(
                Permissions.all.contains(permission),
                "starter permission '\(permission)' is not in Permissions.all — typo or missing registry entry")
        }
    }

    test("starter table has no duplicate permissions") {
        let perms = Bridge.customChannelStarters.map { $0.permission }
        try expectEqual(perms.count, Set(perms).count, "duplicate starter rows would double-start observers")
    }

    test("start(manifest:) primes the channels its permissions grant, and only those") {
        let page = try BridgedPage()
        try page.start(permissions: ["appearance"])
        defer { page.bridge.scope.drain() }
        let pushed = page.pushed("appearance")
        try expect(pushed != nil && pushed != "null", "appearance never primed: \(String(describing: pushed))")
        try expect(page.bridge.lastState["appearance"] != nil, "appearance push not cached for replay")
        try expectEqual(page.bridge.lastState["battery"], nil)
    }
}
