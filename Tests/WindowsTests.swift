import Foundation
import AppKit
import CoreGraphics

// Tests for `Sources/DataSources/Windows.swift`: the pure helpers
// (lifecycle bang detail, addressability-cache verdict rules, create-announce
// dedup, batch frame ledger), the `Windows.all()` shape contract, and the
// negative branch of every `WindowsByID` reader for a window id that names
// no window. Live AX mutations (setFrame / minimize / raise / focus on a real
// window) are not exercised: they would move whatever the user has open.

// Whether raw CGWindowList carries at least one row decode promises to keep
// under includeNonStandard: true — same field requirements as decode's
// guard-let chain, minus the own-pid exclusion it applies. The default
// Windows.all() additionally filters on the AX isStandard probe, and that
// depends on third-party processes' live AX state (headless CI sessions
// resolve none, even with AXIsProcessTrusted() granted) — so the default
// list's count is a fact about the environment, not about decode, and is
// never asserted. Same capability-gate pattern as bluetoothTCCGranted in
// DevicesTests: assert hard where the environment can deliver, skip where
// it can't.
private var rawWindowCandidatesExist: Bool {
    guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
    let ownPid = Int(ProcessInfo.processInfo.processIdentifier)
    return raw.contains { info in
        info[kCGWindowNumber as String] is Int &&
        (info[kCGWindowLayer as String] as? Int) == 0 &&
        info[kCGWindowOwnerName as String] is String &&
        (info[kCGWindowOwnerPID as String] as? Int).map { $0 != ownPid } == true &&
        info[kCGWindowBounds as String] is [String: CGFloat]
    }
}

func registerWindowsTests() {
    // MARK: - WindowsLifecycleObserver.detail (pure: Snap → JSON dict)

    test("detail maps a Snap into the documented bang-detail dict shape") {
        // Every `sd.window.created` / `.destroyed` / `.titleChanged` payload
        // that the polling observer pushes to JS is built here. Locks the
        // exact key set + scalar types that stack authors consume.
        let snap = WindowsLifecycleObserver.Snap(
            id: 42,
            pid: 314,
            app: "Finder",
            title: "Downloads",
            frame: CGRect(x: 100, y: 200, width: 800, height: 600)
        )
        let detail = WindowsLifecycleObserver.detail(snap)
        try expectEqual(detail["id"] as? Int, 42)
        try expectEqual(detail["pid"] as? Int, 314)
        try expectEqual(detail["app"] as? String, "Finder")
        try expectEqual(detail["title"] as? String, "Downloads")
        guard let frame = detail["frame"] as? [String: Int] else {
            throw Expectation(message: "frame missing or not [String: Int]")
        }
        try expectEqual(frame["x"], 100)
        try expectEqual(frame["y"], 200)
        try expectEqual(frame["w"], 800)
        try expectEqual(frame["h"], 600)
    }

    test("detail truncates fractional CGRect components to Int (mirrors Windows.all)") {
        // CGRect uses CGFloat under the hood; AX sometimes hands back
        // sub-pixel origins. The bang detail flattens to Int via direct cast
        // (truncation toward zero), matching how `Windows.all()` shapes its
        // own frame dict in `decode`. Important so consumers don't see
        // mixed Int / Double across the two code paths.
        let snap = WindowsLifecycleObserver.Snap(
            id: 1,
            pid: 1,
            app: "",
            title: "",
            frame: CGRect(x: 10.9, y: -3.4, width: 100.7, height: 50.2)
        )
        let frame = WindowsLifecycleObserver.detail(snap)["frame"] as? [String: Int]
        try expectEqual(frame?["x"], 10)
        try expectEqual(frame?["y"], -3)
        try expectEqual(frame?["w"], 100)
        try expectEqual(frame?["h"], 50)
    }

    test("detail preserves an empty-string title (palette / inspector windows)") {
        // Palettes / inspectors / some menu windows have no AX title; the
        // polling observer carries an empty string through rather than
        // dropping the row. JS consumers (`sd.windows.recents`) rely on the
        // key always being present.
        let snap = WindowsLifecycleObserver.Snap(
            id: 5, pid: 5, app: "ColorSync Utility", title: "",
            frame: .zero
        )
        let detail = WindowsLifecycleObserver.detail(snap)
        try expect(detail["title"] is String, "title key should always exist as String")
        try expectEqual(detail["title"] as? String, "")
    }

    // MARK: - Windows.all() — public CGWindowList shape contract

    test("Windows.all rows (includeNonStandard) carry the documented keys and an Int x/y/w/h frame") {
        // includeNonStandard: true keeps every normal-layer non-own CGWindow,
        // so with raw candidates present, emptiness means decode's field
        // extraction broke. The default Windows.all() additionally filters
        // on the AX isStandard probe, whose result depends on other apps'
        // AX state — its count is never asserted (see rawWindowCandidatesExist).
        let entries = Windows.all(includeNonStandard: true)
        if entries.isEmpty {
            try expect(!rawWindowCandidatesExist,
                       "raw CGWindowList has normal-layer candidates but decode produced 0 rows")
        }
        for entry in entries {
            try expect(entry["id"] is Int, "id should be Int (CGWindowID) in \(entry)")
            try expect(entry["app"] is String, "app should be String (owner name) in \(entry)")
            try expect(entry["pid"] is Int, "pid should be Int (owner pid) in \(entry)")
            try expect(entry["title"] is String, "title should be String (may be empty) in \(entry)")
            try expect(entry["onscreen"] is Bool, "onscreen should be Bool in \(entry)")
            guard let frame = entry["frame"] as? [String: Int] else {
                throw Expectation(message: "frame not [String: Int] in \(entry)")
            }
            try expectEqual(Set(frame.keys), ["x", "y", "w", "h"])
        }
    }

    test("Windows.all ids are unique (one row per CGWindowID)") {
        // Tilers and switchers dedupe by id; a repeated row would double-count
        // a window.
        let ids = Windows.all(includeNonStandard: true).compactMap { $0["id"] as? Int }
        try expectEqual(Set(ids).count, ids.count)
    }

    // MARK: - WindowsByID readers — negative branch for invalid CGWindowID
    //
    // CGWindowID 0 (kCGNullWindowID) never names a window, so elementFor
    // misses and every reader returns its no-handle value: JS sees a
    // deterministic null / false / fallback dict for a stale id, never a
    // partial payload.

    test("WindowsByID optional readers return nil for an invalid window id") {
        try expect(WindowsByID.frame(windowID: 0) == nil, "frame")
        try expect(WindowsByID.title(windowID: 0) == nil, "title")
        try expect(WindowsByID.role(windowID: 0) == nil, "role")
        try expect(WindowsByID.subrole(windowID: 0) == nil, "subrole")
        try expect(WindowsByID.tabs(windowID: 0) == nil, "tabs (nil, not an empty tab list)")
        try expect(WindowsByID.buttonFrames(windowID: 0) == nil, "buttonFrames (nil, not a dict of nulls)")
        try expect(WindowsByID.info(windowID: 0) == nil, "info (nil, not a partial dict)")
    }

    test("WindowsByID bool readers return false for an invalid window id") {
        // sd.windows.byId.isStandard etc. must stay a Bool, never null, so a
        // tiler polling a just-destroyed window keeps working.
        try expectEqual(WindowsByID.isMinimized(windowID: 0), false)
        try expectEqual(WindowsByID.isFullscreen(windowID: 0), false)
        try expectEqual(WindowsByID.hasToolbar(windowID: 0), false)
        try expectEqual(WindowsByID.isStandard(windowID: 0), false)
    }

    test("WindowsByID.cornerHints returns the documented fallback dict for an invalid id") {
        // Never nil: overlay/outline stacks always get all three keys.
        let hints = WindowsByID.cornerHints(windowID: 0)
        try expectEqual(hints["toolbarPresent"] as? Bool, false)
        try expect(hints["role"] is NSNull, "role should be NSNull for invalid id")
        try expect(hints["subrole"] is NSNull, "subrole should be NSNull for invalid id")
    }

    // MARK: - WindowsByID.settleProbe — return-shape contract
    //
    // settleProbe completes via DispatchQueue.main.asyncAfter (the 60ms
    // app-propagation wait), so the tests pump the main runloop until the
    // completion lands.
    func awaitProbe(_ start: (@escaping ([String: Any]) -> Void) -> Void) -> [String: Any]? {
        var result: [String: Any]?
        start { result = $0 }
        let deadline = Date().addingTimeInterval(1.0)
        while result == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }

    test("WindowsByID.settleProbe for an unaddressable windowID keeps ok, actual:NSNull, refused:false") {
        // The probe must always complete with all three keys so the JS
        // shape stays stable. When the window isn't reachable (windowID
        // never existed, app quit), actual is NSNull — not missing — and
        // refusal is unknowable, so false. JS-side destructuring of
        //   const { ok, actual, refused } = await sd.windows.setFrameProbed(...)
        // would otherwise blow up with `actual is undefined`.
        guard let r = awaitProbe({ done in
            WindowsByID.settleProbe(windowID: 0, ok: false, x: 0, y: 0, w: 100, h: 100, completion: done)
        }) else { throw Expectation(message: "probe never completed") }
        try expect(r["ok"] != nil, "ok key missing")
        try expect(r["actual"] != nil, "actual key missing (must be NSNull, not absent)")
        try expect(r["refused"] != nil, "refused key missing")
        try expectEqual(r["ok"] as? Bool, false)
        try expect(r["actual"] is NSNull,
                   "actual should be NSNull for an unaddressable id, got \(type(of: r["actual"]!))")
        try expectEqual(r["refused"] as? Bool, false)
    }

    // MARK: - WindowAddressabilityCache — grace + sticky-success contract
    //
    // Each test uses a unique fake (pid, windowID) so they don't collide with
    // each other or with any real window. The AX read runs off-main, so the
    // tests drive its two halves directly: `verdictNow` is what a caller of
    // probe() gets back (lookup), `readFails` is a finished read whose
    // element did not resolve (record with a nil reading). `invalidate(pid:)`
    // resets both the result cache and the firstSeenAt map per test.
    func verdictNow(pid: pid_t, windowID: CGWindowID, now: TimeInterval) -> WindowAddressabilityCache.Probe {
        WindowAddressabilityCache.lookup(pid: pid, windowID: windowID, now: now).probe
    }
    func readFails(pid: pid_t, windowID: CGWindowID, now: TimeInterval) -> WindowAddressabilityCache.Probe {
        WindowAddressabilityCache.record(pid: pid, windowID: windowID, reading: nil, now: now).probe
    }

    test("WindowAddressabilityCache.probe — grace optimism reports addressable:true, isStandard:false") {
        // Brand-new ids get the optimistic `addressable: true` (so they stay
        // candidates for tile rotation), but isStandard stays false until a
        // real AX probe confirms AXStandardWindow, so a sheet or dialog born
        // while AX is slow is never tiled.
        let pid: pid_t = 7_777_701
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let p = verdictNow(pid: pid, windowID: 7_777_701, now: 1000.0)
        try expectEqual(p.addressable, true)
        try expectEqual(p.isStandard, false)
        try expectEqual(p.isMinimized, false)
    }

    test("WindowAddressabilityCache.probe — grace optimism is NOT cached as sticky-success") {
        // A cached grace result would be read back by the sticky-success
        // branch forever, pinning `isStandard: false` on every window seen
        // during an AX-stress burst. Probe inside grace, then past it: the
        // second call must re-probe and reach `addressable: false`.
        let pid: pid_t = 7_777_702
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let inGrace = readFails(pid: pid, windowID: 7_777_702, now: 1000.0)
        try expectEqual(inGrace.addressable, true)
        try expectEqual(inGrace.isStandard, false)
        // 6.0 seconds later — past the 5.0s optimisticGraceMs window. A
        // poisoned cache would still return the grace result here.
        let pastGrace = readFails(pid: pid, windowID: 7_777_702, now: 1006.0)
        try expectEqual(pastGrace.addressable, false,
                        "grace optimism leaked past graceMs — cache is being poisoned")
        try expectEqual(pastGrace.isStandard, false)
    }

    test("WindowAddressabilityCache.probe — past-grace failure caches with failTtl re-probe gate") {
        // The mirror of the test above: once we're past the grace window
        // a genuine failure verdict IS cached, gated by `failTtl` (0.5s).
        // Locks the cadence so windowscape can rely on `addressable: false`
        // being stable for the duration of a tile pass instead of
        // flickering true→false→true within milliseconds.
        let pid: pid_t = 7_777_703
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        // Seed firstSeenAt so we're past grace immediately.
        _ = readFails(pid: pid, windowID: 7_777_703, now: 1000.0)
        let first = readFails(pid: pid, windowID: 7_777_703, now: 1006.0)
        try expectEqual(first.addressable, false)
        // Within failTtl (< 0.5s) — same Probe instance, ts unchanged.
        let cached = verdictNow(pid: pid, windowID: 7_777_703, now: 1006.1)
        try expectEqual(cached.addressable, false)
        try expectEqual(cached.ts, first.ts,
                        "within failTtl, probe must return cached entry (same ts)")
    }

    test("WindowAddressabilityCache — repeated failures back off the re-probe cadence") {
        // Layer-0 windows AX never vends (helper chrome, other apps'
        // offscreen surfaces) fail every probe. Windows.all() runs on main
        // for every create/destroy/focus push; re-probing each of them every
        // failTtl cost 30–100ms of main per lifecycle event with ~100 such
        // windows. Each consecutive failure doubles the gate, up to a cap.
        typealias P = WindowAddressabilityCache.Probe
        let base = WindowAddressabilityCache.failTtl
        let cap = WindowAddressabilityCache.failTtlCap
        let first = P(addressable: false, isStandard: false, isMinimized: false, ts: 1000.0, failures: 1)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(first, now: 1000.0 + base - 0.01), true)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(first, now: 1000.0 + base), false)
        let third = P(addressable: false, isStandard: false, isMinimized: false, ts: 1000.0, failures: 3)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(third, now: 1000.0 + 4 * base - 0.01), true)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(third, now: 1000.0 + 4 * base), false)
        let many = P(addressable: false, isStandard: false, isMinimized: false, ts: 1000.0, failures: 40)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(many, now: 1000.0 + cap - 0.01), true)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(many, now: 1000.0 + cap), false)
    }

    test("WindowAddressabilityCache — capped failure gates are spread across windows") {
        // Windows that failed the same number of times would otherwise all
        // expire together, and the next Windows.all() would re-probe every
        // one of them at once. The cap is stretched by up to 2x per window id.
        typealias P = WindowAddressabilityCache.Probe
        let cap = WindowAddressabilityCache.failTtlCap
        let many = P(addressable: false, isStandard: false, isMinimized: false, ts: 0, failures: 40)
        let gates = (0..<16).map { wid -> Double in
            // First `now` at which the verdict must be re-probed, to 0.1s.
            var t = 0.0
            while WindowAddressabilityCache.cacheVerdictUsable(many, now: t, windowID: CGWindowID(wid)) { t += 0.1 }
            return t
        }
        try expect(gates.min()! >= cap - 0.11, "no gate below the cap")
        try expect(gates.max()! <= 2 * cap + 0.11, "no gate beyond twice the cap")
        try expect(Set(gates.map { Int($0) }).count >= 8, "gates must differ across window ids: \(gates)")
        // Uncapped gates are left alone so a new window still re-checks fast.
        let first = P(addressable: false, isStandard: false, isMinimized: false, ts: 0, failures: 1)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(first, now: WindowAddressabilityCache.failTtl,
                                                                      windowID: 7), false)
    }

    test("WindowAddressabilityCache.probe — consecutive past-grace failures count up") {
        let pid: pid_t = 7_777_720
        let wid: CGWindowID = 7_777_720
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        _ = readFails(pid: pid, windowID: wid, now: 1000.0)   // grace, uncached
        let f1 = readFails(pid: pid, windowID: wid, now: 1006.0)
        try expectEqual(f1.failures, 1)
        let f2 = readFails(pid: pid, windowID: wid, now: 1006.0 + WindowAddressabilityCache.failTtl)
        try expectEqual(f2.failures, 2)
        // Inside the doubled gate: the cached verdict, not a new probe.
        let held = verdictNow(pid: pid, windowID: wid,
                                                   now: f2.ts + 2 * WindowAddressabilityCache.failTtl - 0.01)
        try expectEqual(held.ts, f2.ts)
        try expectEqual(held.failures, 2)
    }

    test("WindowAddressabilityCache.retryFailures — the next probe re-checks, the backoff count stays") {
        // A space switch can make a window AX would not vend a moment ago
        // addressable; the next Windows.all() must look again at once
        // instead of waiting out a long gate.
        let pid: pid_t = 7_777_721
        let wid: CGWindowID = 7_777_721
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        _ = readFails(pid: pid, windowID: wid, now: 1000.0)
        _ = readFails(pid: pid, windowID: wid, now: 1006.0)
        let f2 = readFails(pid: pid, windowID: wid, now: 1007.0)
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: wid, now: 1007.1).needsRead, false)
        WindowAddressabilityCache.retryFailures()
        try expect(WindowAddressabilityCache.lookup(pid: pid, windowID: wid, now: 1007.1).needsRead,
                   "retryFailures must force a live re-probe")
        let again = readFails(pid: pid, windowID: wid, now: 1007.1)
        try expectEqual(again.failures, f2.failures + 1)
    }

    test("MainStallWatch.report — only passes past the threshold are reported, in whole ms") {
        try expectEqual(MainStallWatch.report(busy: 0.01), nil)
        try expectEqual(MainStallWatch.report(busy: MainStallWatch.threshold), nil)
        let line = MainStallWatch.report(busy: 0.0834)
        try expect(line?.contains("83ms") == true, "got \(String(describing: line))")
    }

    // MARK: - WindowAddressabilityCache.confirm / setMinimized — AX-fed seeding
    //
    // WindowsAXObserver.installPerWindow calls confirm() with the verdict it
    // already read from the live AX element, bypassing probe()'s grace
    // machinery. Without seeding, a window created while AX is busy probes
    // into the optimism grace (isStandard: false), is filtered out of
    // Windows.all(), and the snapshot pumped for its own create bang misses
    // it. All tests use fake pids (no real AX RPC fires on the cache-
    // hit path) and clean up via invalidate(pid:).

    test("WindowAddressabilityCache.confirm seeds a sticky-success verdict that survives past grace") {
        let pid: pid_t = 7_777_704
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 7_777_704,
                                          isStandard: true, isMinimized: false, now: 1000.0)
        let p = verdictNow(pid: pid, windowID: 7_777_704, now: 1000.1)
        try expectEqual(p.addressable, true)
        try expectEqual(p.isStandard, true,
            "AX-confirmed standard verdict must win over grace's isStandard:false")
        // Far past the 5s grace — a probe-derived entry would have had to
        // re-probe (and fail, fake pid); the confirmed entry must stick.
        let late = verdictNow(pid: pid, windowID: 7_777_704, now: 1100.0)
        try expectEqual(late.addressable, true, "confirmed verdict must be sticky, not grace-scoped")
        try expectEqual(late.isStandard, true)
    }

    test("WindowAddressabilityCache.setMinimized flips the bit on an established entry") {
        // The probe's sticky-success fast path never re-reads AX, so the
        // miniaturize/deminiaturize AX events are the ONLY thing keeping
        // isMinimized live. Pin the round-trip both ways.
        let pid: pid_t = 7_777_705
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 7_777_705,
                                          isStandard: true, isMinimized: false, now: 1000.0)
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_705, true)
        let minimized = verdictNow(pid: pid, windowID: 7_777_705, now: 1001.1)
        try expectEqual(minimized.isMinimized, true)
        try expectEqual(minimized.isStandard, true, "setMinimized must not disturb isStandard")
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_705, false)
        let restored = verdictNow(pid: pid, windowID: 7_777_705, now: 1002.1)
        try expectEqual(restored.isMinimized, false)
        try expectEqual(restored.addressable, true)
    }

    test("WindowAddressabilityCache.setMinimized is a no-op for unknown (pid, wid)") {
        // AX can fire miniaturized for a window the cache never probed
        // (e.g. observer installed before any Windows.all() pass). The
        // contract: don't invent an entry — the next real probe reads the
        // live value — and don't crash.
        let pid: pid_t = 7_777_706
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_706, true)
        // Probe goes down the normal (unseeded) path: fake pid → grace
        // optimism with isStandard false, NOT a synthesized minimized entry.
        let p = verdictNow(pid: pid, windowID: 7_777_706, now: 1000.1)
        try expectEqual(p.isMinimized, false,
            "setMinimized on an unknown key must not fabricate cache state")
        try expectEqual(p.isStandard, false)
    }

    test("WindowAddressabilityCache.invalidate(pid:windowID:) drops one key, keeps siblings") {
        // The AX window-destroyed hook. A retained-but-closed window (Preview
        // keeps closed docs in the WindowServer) must lose its sticky
        // isStandard:true so the next probe re-evaluates and drops the ghost
        // from Windows.all() — while the pid's OTHER windows keep their
        // verdicts (per-window destroys must not behave like app-quit).
        let pid: pid_t = 7_777_707
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false, now: 1000.0)
        WindowAddressabilityCache.confirm(pid: pid, windowID: 2, isStandard: true, isMinimized: false, now: 1000.0)
        WindowAddressabilityCache.invalidate(pid: pid, windowID: 1)
        // wid 1: no cache entry left → fake pid probes go down the unseeded
        // path (grace optimism: addressable true but isStandard FALSE).
        let ghost = verdictNow(pid: pid, windowID: 1, now: 1000.1)
        try expectEqual(ghost.isStandard, false,
                        "invalidated window must lose its sticky isStandard verdict")
        // wid 2: untouched sticky success survives.
        let sibling = verdictNow(pid: pid, windowID: 2, now: 1000.1)
        try expectEqual(sibling.isStandard, true, "sibling window's verdict must survive")
    }

    test("WindowAddressabilityCache.standardVerdict — minimized ⇒ standard regardless of subrole reading") {
        // Some apps (Terminal) report AXSubrole == AXDialog for a minimized
        // window; a window first probed while in the Dock must still count
        // as standard or it drops out of Windows.all().
        try expectEqual(WindowAddressabilityCache.standardVerdict(subrole: "AXDialog", isMinimized: true), true)
        try expectEqual(WindowAddressabilityCache.standardVerdict(subrole: nil, isMinimized: true), true)
        try expectEqual(WindowAddressabilityCache.standardVerdict(subrole: "AXStandardWindow", isMinimized: true), true)
    }

    test("WindowAddressabilityCache.standardVerdict — un-minimized readings are trusted as-is") {
        try expectEqual(WindowAddressabilityCache.standardVerdict(subrole: "AXStandardWindow", isMinimized: false), true)
        try expectEqual(WindowAddressabilityCache.standardVerdict(subrole: "AXDialog", isMinimized: false), false)
        try expectEqual(WindowAddressabilityCache.standardVerdict(subrole: nil, isMinimized: false), false)
    }

    test("WindowAddressabilityCache.cacheVerdictUsable — expiry rules per verdict class") {
        typealias P = WindowAddressabilityCache.Probe
        let ttl = WindowAddressabilityCache.nonStandardTtl
        // Positive verdicts (addressable + standard) never expire.
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(
            P(addressable: true, isStandard: true, isMinimized: false, ts: 0), now: 1e9), true)
        // Negative isStandard: usable while fresh, must re-probe once the
        // TTL elapses — the permanent-poison guard.
        let neg = P(addressable: true, isStandard: false, isMinimized: false, ts: 1000.0)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(neg, now: 1000.0 + ttl - 0.1), true)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(neg, now: 1000.0 + ttl), false)
        // Unaddressable: the aggressive failTtl cadence (0.5s), unchanged.
        let fail = P(addressable: false, isStandard: false, isMinimized: false, ts: 1000.0)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(fail, now: 1000.4), true)
        try expectEqual(WindowAddressabilityCache.cacheVerdictUsable(fail, now: 1000.6), false)
    }

    test("WindowAddressabilityCache — negative isStandard verdict expires after nonStandardTtl") {
        // Pins the permanent-poison guard: positive verdicts stay sticky,
        // negative isStandard verdicts re-probe once nonStandardTtl has
        // elapsed. Full transition-race story: the nonStandardTtl comment
        // in WindowAddressabilityCache.
        let pid: pid_t = 7_777_708
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 7_777_708,
                                          isStandard: false, isMinimized: false, now: 1000.0)
        // Within TTL: cached entry returned untouched (same ts).
        let cached = verdictNow(pid: pid, windowID: 7_777_708, now: 1001.0)
        try expectEqual(cached.isStandard, false)
        try expectEqual(cached.ts, 1000.0,
                        "within nonStandardTtl the cached entry must be returned as-is")
        // Past TTL: a live re-probe must happen. AX fails for the fake pid,
        // so the sticky-preserve branch keeps the verdict but stamps ts=now
        // — the observable proof a re-probe was attempted.
        try expect(WindowAddressabilityCache.lookup(pid: pid, windowID: 7_777_708, now: 1004.0).needsRead,
                   "past nonStandardTtl the verdict must be re-read")
        let reprobed = readFails(pid: pid, windowID: 7_777_708, now: 1004.0)
        try expectEqual(reprobed.addressable, true)
        try expectEqual(reprobed.isStandard, false)
        try expectEqual(reprobed.ts, 1004.0,
                        "past nonStandardTtl the probe must re-read AX (sticky-preserve stamps ts)")
        // One-TTL-per-failure pacing: the failed re-probe buys one more TTL
        // of patience — not a permanent verdict, not a hot loop.
        let paced = verdictNow(pid: pid, windowID: 7_777_708, now: 1005.0)
        try expectEqual(paced.ts, 1004.0,
                        "failed re-probe must hold for one more TTL, not re-probe every call")
    }

    test("WindowAddressabilityCache.setMinimized preserves the entry's ts (no TTL extension)") {
        // ts schedules a negative verdict's re-probe; re-stamping it here
        // would let minimize churn extend the heal deadline indefinitely.
        let pid: pid_t = 7_777_709
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 7_777_709,
                                          isStandard: false, isMinimized: false, now: 1000.0)
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_709, true)
        // With ts preserved at 1000.0 the TTL is expired by 1004.0 →
        // re-probe → sticky-preserve stamps ts=now. Had setMinimized
        // stamped ts=1002.5, the entry would still read as fresh and come
        // back untouched.
        try expect(WindowAddressabilityCache.lookup(pid: pid, windowID: 7_777_709, now: 1004.0).needsRead,
                   "setMinimized must not reset the negative-verdict re-probe clock")
        let p = readFails(pid: pid, windowID: 7_777_709, now: 1004.0)
        try expectEqual(p.ts, 1004.0,
                        "setMinimized must not reset the negative-verdict re-probe clock")
        try expectEqual(p.isMinimized, true,
                        "the minimized flip itself must survive the re-probe")
    }

    // MARK: - CreateAnnouncementLedger — single-owner create dedup
    //
    // All three create announcers (AX observer, CGS 1325 fast path, 10s
    // poll) funnel through WindowLifecycleFanout.fireCreated, which
    // check-and-marks against this ledger, so no announcer can skip half of
    // the dedup protocol.

    test("CreateAnnouncementLedger announces once per window per TTL") {
        var l = CreateAnnouncementLedger()
        try expect(l.shouldAnnounce(id: 1, now: 0), "first announce passes")
        try expect(!l.shouldAnnounce(id: 1, now: 1.0), "second within TTL dedups")
        try expect(l.shouldAnnounce(id: 2, now: 1.0), "windows must not couple")
        try expect(l.shouldAnnounce(id: 1, now: 0 + CreateAnnouncementLedger.ttl + 0.1),
                   "post-TTL re-announce passes (window id reuse)")
    }

    test("CreateAnnouncementLedger read-only recency view for the poll gate") {
        var l = CreateAnnouncementLedger()
        try expect(!l.announcedRecently(id: 3, now: 0), "unknown id")
        _ = l.shouldAnnounce(id: 3, now: 0)
        try expect(l.announcedRecently(id: 3, now: 5.0), "inside TTL")
        try expect(!l.announcedRecently(id: 3, now: CreateAnnouncementLedger.ttl + 0.1), "expired")
    }

    // MARK: - Batch — all-AX queued commit
    //
    // A batch queues full frames (last write wins per window) and applies
    // them all through the normal AX setFrame path in one burst at commit,
    // so size and position never travel on separate channels. begin fails
    // only when a batch is already open. The frame applier is injected, so
    // the bogus window ids below are never written.

    test("BatchFrameLedger records last-write-wins per window id in first-seen order") {
        var ledger = WindowsByID.BatchFrameLedger()
        ledger.record(id: 101, frame: CGRect(x: 10, y: 20, width: 100, height: 100))
        ledger.record(id: 202, frame: CGRect(x: 30, y: 40, width: 200, height: 200))
        ledger.record(id: 101, frame: CGRect(x: 50, y: 60, width: 300, height: 300))
        let drained = ledger.drain()
        try expectEqual(drained.count, 2)
        try expectEqual(drained[0].id, 101)
        try expectEqual(drained[0].frame, CGRect(x: 50, y: 60, width: 300, height: 300),
                        "second record for id 101 must overwrite the first")
        try expectEqual(drained[1].id, 202)
        try expectEqual(drained[1].frame, CGRect(x: 30, y: 40, width: 200, height: 200))
    }

    test("BatchFrameLedger.drain empties the ledger (no replay across batches)") {
        var ledger = WindowsByID.BatchFrameLedger()
        ledger.record(id: 7, frame: .zero)
        _ = ledger.drain()
        try expectEqual(ledger.drain().count, 0,
                        "a drained ledger must not replay stale frames into the next batch")
    }

    test("beginBatch always opens unless a batch is already open") {
        try expectEqual(WindowsByID.beginBatch(), true, "begin opens a batch")
        try expectEqual(WindowsByID.beginBatch(), false, "no nesting")
        _ = WindowsByID.commitBatch { _, _ in }
    }

    test("commitBatch applies every queued frame through the frame applier, then closes") {
        guard WindowsByID.beginBatch() else { throw Expectation(message: "begin refused") }
        // Bogus ids; the injected applier means no AX write ever fires.
        WindowsByID.batchSink?(4_294_000_001, CGRect(x: 100, y: 200, width: 640, height: 480))
        WindowsByID.batchSink?(4_294_000_002, CGRect(x: 300, y: 400, width: 800, height: 600))
        var captured: [(id: CGWindowID, frame: CGRect)] = []
        let ok = WindowsByID.commitBatch { id, frame in captured.append((id: id, frame: frame)) }
        try expectEqual(ok, true)
        try expectEqual(captured.count, 2,
                        "every queued frame must be applied at commit")
        try expectEqual(captured[0].id, 4_294_000_001)
        try expectEqual(captured[0].frame, CGRect(x: 100, y: 200, width: 640, height: 480))
        try expectEqual(captured[1].id, 4_294_000_002)
        try expectEqual(captured[1].frame, CGRect(x: 300, y: 400, width: 800, height: 600))
        // Commit must have closed the batch: no sink, second commit refuses.
        try expect(WindowsByID.batchSink == nil, "commit must clear the sink")
        try expectEqual(WindowsByID.commitBatch { _, _ in }, false)
    }

    test("commitBatch with no queued frames applies nothing; next batch starts clean") {
        guard WindowsByID.beginBatch() else { throw Expectation(message: "begin refused") }
        var applied = 0
        try expectEqual(WindowsByID.commitBatch { _, _ in applied += 1 }, true)
        try expectEqual(applied, 0)
        // A fresh batch must not inherit frames from a previous one.
        guard WindowsByID.beginBatch() else { throw Expectation(message: "begin refused") }
        WindowsByID.batchSink?(4_294_000_003, CGRect(x: 1, y: 2, width: 3, height: 4))
        var captured: [CGWindowID] = []
        _ = WindowsByID.commitBatch { id, _ in captured.append(id) }
        try expectEqual(captured, [4_294_000_003])
    }

    test("setFrame inside an open batch queues instead of writing") {
        guard WindowsByID.beginBatch() else { throw Expectation(message: "begin refused") }
        // A bogus id would fail element lookup on the direct path; queueing
        // must succeed regardless because commit owns the lookup.
        try expectEqual(
            WindowsByID.setFrame(windowID: 4_294_000_004, x: 5, y: 6, w: 700, h: 500), true,
            "batched setFrame returns true (queued)")
        var captured: [(id: CGWindowID, frame: CGRect)] = []
        _ = WindowsByID.commitBatch { id, frame in captured.append((id: id, frame: frame)) }
        try expectEqual(captured.count, 1)
        try expectEqual(captured[0].id, 4_294_000_004)
        try expectEqual(captured[0].frame, CGRect(x: 5, y: 6, width: 700, height: 500))
    }
}
