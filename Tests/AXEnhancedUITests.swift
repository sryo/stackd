import Foundation

// AXEnhancedUI — the scoped toggle of an app's AXEnhancedUserInterface
// (menu walks turn it on; motion write batches turn it off, since apps with
// it on animate their own frame changes), and the per-app probe cache the
// AX frame writers keep.
func registerAXEnhancedUITests() {
    test("AXEnhancedUI.plan: turning off an app that has it on restores it after") {
        try expectEqual(AXEnhancedUI.plan(prior: true, want: false),
                        AXEnhancedUI.Plan(set: false, restore: true))
    }

    test("AXEnhancedUI.plan: already at the wanted value touches nothing") {
        try expectEqual(AXEnhancedUI.plan(prior: false, want: false), AXEnhancedUI.Plan(set: nil, restore: nil))
        try expectEqual(AXEnhancedUI.plan(prior: true, want: true), AXEnhancedUI.Plan(set: nil, restore: nil))
    }

    test("AXEnhancedUI.plan: an app that doesn't expose it counts as off") {
        try expectEqual(AXEnhancedUI.plan(prior: nil, want: false), AXEnhancedUI.Plan(set: nil, restore: nil))
        try expectEqual(AXEnhancedUI.plan(prior: nil, want: true),
                        AXEnhancedUI.Plan(set: true, restore: false))
    }

    test("AXEnhancedUIProbeCache: probes once, then serves the cached value until it ages out") {
        var cache = AXEnhancedUIProbeCache()
        var probes = 0
        let probe: () -> Bool? = { probes += 1; return true }
        try expectEqual(cache.value(now: 10, probe: probe), true)
        try expectEqual(cache.value(now: 10 + AXEnhancedUIProbeCache.ttl - 0.01, probe: probe), true)
        try expectEqual(probes, 1)
        _ = cache.value(now: 10 + AXEnhancedUIProbeCache.ttl + 0.01, probe: probe)
        try expectEqual(probes, 2)
    }

    test("AXEnhancedUIProbeCache: an unreadable attribute is cached too") {
        var cache = AXEnhancedUIProbeCache()
        var probes = 0
        let probe: () -> Bool? = { probes += 1; return nil }
        try expectEqual(cache.value(now: 0, probe: probe), nil)
        try expectEqual(cache.value(now: 0.5, probe: probe), nil)
        try expectEqual(probes, 1)
    }
}
