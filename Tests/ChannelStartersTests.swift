import Foundation

/// Guards the joint between `Channels.all` (the channel registry) and
/// `Bridge.channelStarters` (the permission → starter table walked by
/// `Bridge.start(manifest:)`). Before the table existed, a new replayable
/// `Channel(...)` whose permission was missing from the hand-written
/// if-chain compiled fine and silently never replayed — `replayState()`
/// found no `lastState` because nothing ever started the producer.
func registerChannelStartersTests() {
    // "app"/"windows" share startWorkspace (combined starter with
    // per-permission payload gating) — served, but not table rows.
    let workspaceServed: Set<String> = ["app", "windows"]

    test("every replayable channel's permission has a starter") {
        let starterPerms = Set(Bridge.channelStarters.map { $0.permission })
            .union(workspaceServed)
        for ch in Channels.all where ch.replayable {
            try expect(
                starterPerms.contains(ch.permission),
                "channel '\(ch.name)' (permission '\(ch.permission)') has no starter — it will never produce or replay state")
        }
    }

    test("starter table permissions are all registered in Permissions.all") {
        for (permission, _) in Bridge.channelStarters {
            try expect(
                Permissions.all.contains(permission),
                "starter permission '\(permission)' is not in Permissions.all — typo or missing registry entry")
        }
    }

    test("starter table has no duplicate permissions") {
        let perms = Bridge.channelStarters.map { $0.permission }
        try expectEqual(perms.count, Set(perms).count, "duplicate starter rows would double-start observers")
    }
}
