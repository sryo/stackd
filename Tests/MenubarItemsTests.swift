import Foundation

// Tests for the pure helpers behind `sd.menubar.items` / `sd.menubar.observe`.
// The AX walk itself is impure (talks to live SystemUIServer + every app's
// AXMenuBarItem children) and depends on TCC + on whatever third-party
// menubar apps the user happens to have running — meaningless to unit-test.
//
// The bug surface that CAN be tested in isolation:
//   - isHidden(itemX:itemWidth:screenLeft:screenRight:) — classification of
//     items pushed past the chevron / off-screen. Cross-version stable
//     math; regressions silently flip "hidden" on every consumer.
//   - resolveOwner(pid:cache:resolver:) — owner-name fallback chain
//     (bundleId → name → "pid:NNNN"). Same dict-shape contract stacks
//     consume.

func registerMenubarItemsTests() {
    // MARK: - isHidden

    test("isHidden returns false for an item fully inside the visible bar") {
        // Standard third-party item at x=1200 on a 1440-wide screen.
        try expectEqual(
            MenubarItems.isHidden(itemX: 1200, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            false
        )
    }

    test("isHidden returns true for an item entirely left of the screen") {
        // Pushed past the chevron — sits at negative X, fully off-screen left.
        try expectEqual(
            MenubarItems.isHidden(itemX: -100, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            true
        )
    }

    test("isHidden returns true for an item past the screen's right edge") {
        // Too many items / not enough room — overflows right of the visible bar.
        try expectEqual(
            MenubarItems.isHidden(itemX: 1500, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            true
        )
        // Left edge exactly at screenRight: zero visible width.
        try expectEqual(
            MenubarItems.isHidden(itemX: 1440, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            true
        )
    }

    test("isHidden returns false for an item only partly off the left edge") {
        // Any visible sliver counts as shown.
        try expectEqual(
            MenubarItems.isHidden(itemX: -10, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            false
        )
    }

    test("isHidden returns false for an item flush against the right edge") {
        // Right edge of the item exactly meets screenRight — still visible.
        // (itemX=1416, width=24 → right=1440, matches screenRight.)
        try expectEqual(
            MenubarItems.isHidden(itemX: 1416, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            false
        )
    }

    test("isHidden returns true when right edge touches screenLeft (zero overlap)") {
        // itemX=-24, width=24 → right=0 = screenLeft. No visible portion.
        try expectEqual(
            MenubarItems.isHidden(itemX: -24, itemWidth: 24, screenLeft: 0, screenRight: 1440),
            true
        )
    }

    // MARK: - resolveOwner

    test("resolveOwner prefers bundleId when present") {
        var cache: [pid_t: String] = [:]
        let owner = MenubarItems.resolveOwner(pid: 42, cache: &cache) { _ in
            (bundleId: "com.example.app", name: "Example")
        }
        try expectEqual(owner, "com.example.app")
        try expectEqual(cache[42], "com.example.app")
    }

    test("resolveOwner falls back to process name when bundleId is missing") {
        // Some helpers / agents don't carry a bundle identifier — fall through
        // to the localized name rather than dropping the row.
        var cache: [pid_t: String] = [:]
        let owner = MenubarItems.resolveOwner(pid: 99, cache: &cache) { _ in
            (bundleId: nil, name: "Helper")
        }
        try expectEqual(owner, "Helper")
        try expectEqual(cache[99], "Helper")
    }

    test("resolveOwner falls back to 'pid:N' when both bundleId and name are absent") {
        // Defensive: NSRunningApplication can return an instance whose
        // bundleIdentifier / localizedName are both nil for orphaned PIDs.
        // The fallback keeps JS from receiving empty-string owners.
        var cache: [pid_t: String] = [:]
        let owner = MenubarItems.resolveOwner(pid: 1234, cache: &cache) { _ in nil }
        try expectEqual(owner, "pid:1234")
    }

    test("resolveOwner returns the cached value without re-invoking the resolver") {
        // Cache hit short-circuits the (potentially expensive) lookup.
        var cache: [pid_t: String] = [7: "com.cached.app"]
        var invocations = 0
        let owner = MenubarItems.resolveOwner(pid: 7, cache: &cache) { _ in
            invocations += 1
            return (bundleId: "com.fresh.app", name: nil)
        }
        try expectEqual(owner, "com.cached.app")
        try expectEqual(invocations, 0)
    }

    test("resolveOwner ignores empty bundleId and falls through to name") {
        // NSRunningApplication can return an empty-string bundleIdentifier
        // for stripped helpers; treat empty the same as nil.
        var cache: [pid_t: String] = [:]
        let owner = MenubarItems.resolveOwner(pid: 11, cache: &cache) { _ in
            (bundleId: "", name: "Stripped")
        }
        try expectEqual(owner, "Stripped")
    }

    // MARK: - MenubarItemsObserver subscriber-gating
    //
    // MenubarItemsObserver walks every app's AX menubar items on a timer; it
    // must stay idle until a stack subscribes. The generic
    // subscribe/debounce/teardown lifecycle is covered by
    // RefCountedObserverTests (subscribing here would run a live AX walk).

    test("MenubarItemsObserver: inactive at startup (no subscribers)") {
        try expect(!MenubarItemsObserver.shared.isActive,
                   "MenubarItemsObserver must not be active before any stack subscribes")
    }

    // MARK: - MenubarExtrasCandidates (which processes to ask for status items)

    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    test("MenubarExtrasCandidates probes every pid it has not seen") {
        var c = MenubarExtrasCandidates()
        let pids = c.pidsToProbe(running: [3, 1, 2], now: t0, recheckAfter: 30, staleBudget: 2)
        try expectEqual(Set(pids), [1, 2, 3])
    }

    test("MenubarExtrasCandidates keeps asking owners and leaves recently empty pids alone") {
        var c = MenubarExtrasCandidates()
        c.record(pid: 1, hasExtras: true, now: t0)
        c.record(pid: 2, hasExtras: false, now: t0)
        let pids = c.pidsToProbe(running: [1, 2, 3], now: t0.addingTimeInterval(5),
                                 recheckAfter: 30, staleBudget: 2)
        try expectEqual(Set(pids), [1, 3])
    }

    test("MenubarExtrasCandidates re-asks stale empty pids oldest first, within the budget") {
        var c = MenubarExtrasCandidates()
        c.record(pid: 4, hasExtras: false, now: t0.addingTimeInterval(2))
        c.record(pid: 2, hasExtras: false, now: t0)
        c.record(pid: 3, hasExtras: false, now: t0.addingTimeInterval(1))
        let pids = c.pidsToProbe(running: [2, 3, 4], now: t0.addingTimeInterval(40),
                                 recheckAfter: 30, staleBudget: 2)
        try expectEqual(pids, [2, 3])
    }

    test("MenubarExtrasCandidates forgets exited pids so a reused pid is asked again") {
        var c = MenubarExtrasCandidates()
        c.record(pid: 2, hasExtras: false, now: t0)
        c.record(pid: 5, hasExtras: true, now: t0)
        _ = c.pidsToProbe(running: [1], now: t0.addingTimeInterval(1), recheckAfter: 30, staleBudget: 2)
        let pids = c.pidsToProbe(running: [2, 5], now: t0.addingTimeInterval(2),
                                 recheckAfter: 30, staleBudget: 2)
        try expectEqual(Set(pids), [2, 5])
        try expect(!c.owners.contains(5), "an exited owner must not stay an owner")
    }

    test("MenubarExtrasCandidates: a failed read never demotes an owner") {
        var c = MenubarExtrasCandidates()
        c.record(pid: 1, hasExtras: true, now: t0)
        c.record(pid: 1, hasExtras: false, now: t0.addingTimeInterval(1))
        let pids = c.pidsToProbe(running: [1], now: t0.addingTimeInterval(2), recheckAfter: 30, staleBudget: 0)
        try expectEqual(pids, [1])
    }

    // The live read: the system clock's menu extra is always in the bar, so
    // a trusted process must see at least one item whichever route (system-
    // wide or per-app) the running macOS supports.
    test("MenubarItemsObserver.snapshot lists the bar's status items when Accessibility is granted") {
        guard AXIsProcessTrusted() else { return }
        let items = MenubarItemsObserver.shared.snapshot()
        try expect(!items.isEmpty, "no status items read from a trusted process")
        for item in items {
            try expect(item["owner"] is String && item["x"] is Double && item["width"] is Double
                       && item["hidden"] is Bool && item["title"] is String,
                       "item lost its dict shape: \(item)")
        }
    }
}
