import Foundation
import AppKit
import CoreGraphics

// Tests for `Sources/DataSources/Windows.swift`.
//
// Like Apps.swift, Windows.swift exposes almost no extracted pure helpers:
// every `static` is wired straight into either CGWindowList, the AX
// (Accessibility) APIs, or the private SkyLight (CGS) SPI. There is no
// `clampedFps` / `isHidden(itemX:...)` knob to hammer in isolation.
//
// What CAN be characterized without mutating live macOS state:
//
//   1. `WindowsLifecycleObserver.detail(_:)` — the ONE genuinely pure helper
//      in the file. Snap → JSON-able dict mapping that the bang fan-out and
//      every `sd.window.*` consumer relies on. Stable, no side effects.
//
//   2. `Windows.all()` shape contract — `CGWindowListCopyWindowInfo` is a
//      public, no-prompt read. We characterize the dict contract (id / app /
//      pid / title / onscreen / frame{x,y,w,h}) that JS consumers depend on
//      without depending on which specific windows are open. Non-emptiness
//      is asserted only for `includeNonStandard: true` and only when raw
//      CGWindowList carries qualifying candidates — the default list's
//      isStandard filter rides on third-party AX state that headless
//      sessions never satisfy. See `rawWindowCandidatesExist`.
//
//   3. Negative branches of every `WindowsByID.*` reader for an obviously-
//      invalid CGWindowID — `elementFor(windowID:)` walks CGWindowList and
//      returns nil on miss, so every downstream reader short-circuits to
//      its documented "no AX handle" return (nil / false / empty hints).
//      This locks the contract that JS sees a deterministic type, never a
//      hang or crash, for stale window ids.
//
//   4. `WindowsByID.invalidateCache(pid:)` / `invalidateAll()` — pure cache
//      mutations, idempotent, safe to call repeatedly. They have no return
//      value but characterizing "doesn't throw, doesn't crash" matters
//      because they're called from the lifecycle observer on destroy.
//
// What is NOT covered here (by design):
//
//   - `Windows.setFocusedFrame` / `minimizeFocused` / `fullscreenFocused` /
//     `raiseFocused` — would move / minimize / fullscreen the real frontmost
//     window of whatever app is up while the test suite runs.
//   - `WindowsByID.setFrame` / `minimize` / `fullscreen` / `raise` / `focus`
//     / `close` / `focusTab` — same reason: live AX mutations.
//   - `WindowsByID.setFrame` routed through a live batch — needs a real
//     window to observe convergence; covered by the batch lifecycle tests
//     below only up to the sink/ledger/commit contract (bogus CGWindowIDs,
//     injected position applier — no user window is mutated; an SLS move on
//     an id WindowServer doesn't know is a per-op error the tx ignores).
//   - `WindowsByID.snapshot` — exercises the SkyLight HW-capture SPI; safe
//     to read but environment-dependent (depends on which windows exist).
//   - The CGS event callback (`windowEventsCallback`) and the
//     `WindowsLifecycleObserver` timer loop — both are wire-into-WindowServer
//     state with no isolatable surface.
//
// Pattern mirrors AppsTests + MenubarItemsTests: pure helpers get the full
// table-driven treatment; AX-coupled readers get negative-input contract
// pinning so the JS-visible return type stays deterministic.

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

    test("Windows.all keeps raw candidates (includeNonStandard) with the documented per-entry keys") {
        // includeNonStandard: true keeps every normal-layer non-own CGWindow,
        // so with raw candidates present, emptiness means decode's field
        // extraction broke — assertable in any session that has windows at
        // all. (The default Windows.all() additionally filters on the AX
        // isStandard probe, which resolves nothing in headless sessions —
        // its count is never asserted, see rawWindowCandidatesExist.)
        let entries = Windows.all(includeNonStandard: true)
        guard let first = entries.first else {
            try expect(!rawWindowCandidatesExist,
                       "raw CGWindowList has normal-layer candidates but decode produced 0 rows")
            return
        }
        try expect(first["id"] is Int, "id should be Int (CGWindowID)")
        try expect(first["app"] is String, "app should be String (owner name)")
        try expect(first["pid"] is Int, "pid should be Int (owner pid)")
        try expect(first["title"] is String, "title should be String (may be empty)")
        try expect(first["onscreen"] is Bool, "onscreen should be Bool")
        try expect(first["frame"] is [String: Int], "frame should be [String: Int]")
    }

    test("Windows.all frame dict carries x/y/w/h as Int") {
        // The `decode` helper flattens kCGWindowBounds (CGFloat dict) into
        // an Int-keyed sub-dict. Every entry should have all four keys —
        // a missing dimension is a bug that breaks any JS frame consumer.
        for entry in Windows.all(includeNonStandard: true) {
            guard let frame = entry["frame"] as? [String: Int] else {
                throw Expectation(message: "frame not [String: Int] in \(entry)")
            }
            try expect(frame["x"] != nil, "frame missing x")
            try expect(frame["y"] != nil, "frame missing y")
            try expect(frame["w"] != nil, "frame missing w")
            try expect(frame["h"] != nil, "frame missing h")
        }
    }

    test("Windows.all ids are unique (one row per CGWindowID)") {
        // CGWindowList keys by window number; if `decode` ever dropped that
        // invariant, JS dedup logic in tilers / window switchers would
        // double-count the same window. includeNonStandard for the widest
        // row set; emptiness only counts as a failure when raw candidates
        // exist (see rawWindowCandidatesExist).
        let ids = Windows.all(includeNonStandard: true).compactMap { $0["id"] as? Int }
        guard !ids.isEmpty else {
            try expect(!rawWindowCandidatesExist,
                       "no ids extracted from Windows.all despite raw CGWindowList candidates")
            return
        }
        try expectEqual(Set(ids).count, ids.count)
    }

    // MARK: - WindowsByID readers — negative branch for invalid CGWindowID

    test("WindowsByID.frame returns nil for an obviously-invalid window id") {
        // CGWindowID 0 is reserved (kCGNullWindowID) and never names a real
        // window. The CGWindowList scan in `elementFor(windowID:)` misses,
        // every downstream reader short-circuits to its no-handle return.
        try expect(WindowsByID.frame(windowID: 0) == nil,
                   "expected nil frame for windowID 0")
    }

    test("WindowsByID title/role/subrole return nil for an invalid window id") {
        // Same negative branch — locks the contract that JS sees `null`
        // (via the `Any? ?? NSNull()` wrap in Bridge) and not a hang.
        try expect(WindowsByID.title(windowID: 0) == nil,
                   "expected nil title for windowID 0")
        try expect(WindowsByID.role(windowID: 0) == nil,
                   "expected nil role for windowID 0")
        try expect(WindowsByID.subrole(windowID: 0) == nil,
                   "expected nil subrole for windowID 0")
    }

    test("WindowsByID bool readers return false for an invalid window id") {
        // `isMinimized` / `isFullscreen` / `hasToolbar` / `isStandard` all
        // gate on `elementFor(windowID:)`; on miss they bail to `false`. JS
        // consumers (`sd.windows.byId.isStandard`) depend on the Bool never
        // being `null` for stale ids — a tiler that polls a just-destroyed
        // window must keep working.
        try expectEqual(WindowsByID.isMinimized(windowID: 0), false)
        try expectEqual(WindowsByID.isFullscreen(windowID: 0), false)
        try expectEqual(WindowsByID.hasToolbar(windowID: 0), false)
        try expectEqual(WindowsByID.isStandard(windowID: 0), false)
    }

    test("WindowsByID.tabs returns nil for an invalid window id") {
        // No AX element → no tab group → nil. Distinct from "AXTabGroup
        // exists but is empty" which returns `[]`; this test pins the
        // "no window at all" branch.
        try expect(WindowsByID.tabs(windowID: 0) == nil,
                   "expected nil tabs for windowID 0")
    }

    test("WindowsByID.cornerHints returns the documented fallback dict for an invalid id") {
        // Never returns nil — the daemon contract is that overlay/outline
        // stacks always get a dict with the three keys present so the JS
        // side doesn't have to defensively branch on missing keys.
        let hints = WindowsByID.cornerHints(windowID: 0)
        try expectEqual(hints["toolbarPresent"] as? Bool, false)
        try expect(hints["role"] is NSNull, "role should be NSNull for invalid id")
        try expect(hints["subrole"] is NSNull, "subrole should be NSNull for invalid id")
    }

    // MARK: - WindowsByID cache invalidation — non-throwing side effects

    test("WindowsByID.invalidateAll runs without crashing on an empty cache") {
        // Lifecycle observer fires this on `sd.window.destroyed`; pinning
        // the no-op behavior so a destroy on a never-cached pid stays safe.
        WindowsByID.invalidateAll()
        WindowsByID.invalidateAll()  // idempotent
        try expect(true, "invalidateAll did not crash")
    }

    test("WindowsByID.invalidateCache(pid:) is safe for an unknown pid") {
        // Same no-op contract for the pid-scoped variant. CGS create/destroy
        // events come in with whatever pid WindowServer reports — including
        // pids we've never seen a window from.
        WindowsByID.invalidateCache(pid: 0)
        WindowsByID.invalidateCache(pid: -1)
        WindowsByID.invalidateCache(pid: 999999)
        try expect(true, "invalidateCache(pid:) did not crash for unknown pids")
    }

    // MARK: - WindowsByID.buttonFrames — traffic-light reader

    test("WindowsByID.buttonFrames returns nil for an unaddressable windowID") {
        // buttonFrames batches three AX attribute reads (close/zoom/minimize
        // → AXPosition + AXSize each) into one daemon round-trip. When the
        // windowID doesn't resolve via elementFor, the contract is nil (not
        // a partial dict with three nulls). Mirrors info()'s nil contract;
        // lets the stack-side interceptor fall through to a no-op cleanly
        // when a stale id is queried mid-tick.
        let result = WindowsByID.buttonFrames(windowID: 0)
        try expect(result == nil,
                   "buttonFrames(0) returned non-nil: \(String(describing: result))")
    }

    // MARK: - WindowsByID.info — batch reader

    test("WindowsByID.info returns nil for an unaddressable windowID") {
        // info() consolidates frame/title/role/subrole/isMinimized/isFullscreen
        // /isStandard/hasToolbar/cornerHints into one AX lookup. For an id
        // that doesn't resolve via elementFor, the contract is nil (not a
        // partial dict). Mirrors WindowsByID.frame's nil contract; lets
        // callers fall through to a no-op cleanly.
        let result = WindowsByID.info(windowID: 0)
        try expect(result == nil, "info(0) returned non-nil: \(String(describing: result))")
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

    test("WindowsByID.settleProbe actual frame, when present, exposes the x/y/w/h key set") {
        // Shape contract: when CG yields back a frame, it MUST contain all
        // four keys with Double values (matches sd.windows.frame's contract).
        // We can't force a real window in tests; skip the body if no window
        // is reachable. The unaddressable-id test above covers the failure
        // branch.
        guard let r = awaitProbe({ done in
            WindowsByID.settleProbe(windowID: 0, ok: false, x: 0, y: 0, w: 100, h: 100, completion: done)
        }), let actual = r["actual"] as? [String: Any] else { return }
        try expect(actual["x"] is Double, "x should be Double, got \(type(of: actual["x"] ?? "nil"))")
        try expect(actual["y"] is Double, "y should be Double")
        try expect(actual["w"] is Double, "w should be Double")
        try expect(actual["h"] is Double, "h should be Double")
    }

    // MARK: - WindowAddressabilityCache.probe — grace + sticky-success contract
    //
    // Each test uses a unique fake (pid, windowID) so they don't collide with
    // each other or with any real window. `AXUIElementCreateApplication(pid)`
    // for a pid that owns no windows returns an empty AXWindows array, so
    // `WindowsByID.elementFor(pid:)` returns nil, driving the probe down its
    // unaddressable branches deterministically. `invalidate(pid:)` resets
    // both the result cache and the firstSeenAt map per test.

    test("WindowAddressabilityCache.probe — grace optimism reports addressable:true, isStandard:false") {
        // Locks the post-aef9f4e contract: brand-new IDs get the optimistic
        // `addressable: true` (so they stay candidate for tile rotation),
        // but isStandard stays false until a real AX probe confirms
        // AXStandardWindow. Prevents the prior bug where sheets/dialogs
        // born during AX-stress inherited isStandard: true and got tiled.
        let pid: pid_t = 7_777_701
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let p = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_701, now: 1000.0)
        try expectEqual(p.addressable, true)
        try expectEqual(p.isStandard, false)
        try expectEqual(p.isMinimized, false)
    }

    test("WindowAddressabilityCache.probe — grace optimism is NOT cached as sticky-success") {
        // Regression: prior to this fix, the grace path stored its
        // `addressable: true` result in the same cache the sticky-success
        // branch reads, so the next probe returned the lie permanently.
        // Every window the daemon saw during an AX-stress burst (boot,
        // full restart, spotlight indexing) ended up flagged
        // `isStandard: false` for its entire lifetime and silently dropped
        // out of windowscape's tile rotation. The check: probe twice — once
        // inside grace, once past grace — and demand the second call
        // re-probes (verdict goes to `addressable: false` once the optimism
        // budget runs out). If the grace result had stickied, the second
        // call would echo the cached `addressable: true`.
        let pid: pid_t = 7_777_702
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let inGrace = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_702, now: 1000.0)
        try expectEqual(inGrace.addressable, true)
        try expectEqual(inGrace.isStandard, false)
        // 6.0 seconds later — past the 5.0s optimisticGraceMs window. A
        // poisoned cache would still return the grace result here.
        let pastGrace = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_702, now: 1006.0)
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
        _ = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_703, now: 1000.0)
        let first = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_703, now: 1006.0)
        try expectEqual(first.addressable, false)
        // Within failTtl (< 0.5s) — same Probe instance, ts unchanged.
        let cached = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_703, now: 1006.1)
        try expectEqual(cached.addressable, false)
        try expectEqual(cached.ts, first.ts,
                        "within failTtl, probe must return cached entry (same ts)")
    }

    // MARK: - WindowAddressabilityCache.confirm / setMinimized — AX-fed seeding
    //
    // WindowsAXObserver.installPerWindow calls confirm() with the verdict it
    // already read from the live AX element, bypassing probe()'s grace
    // machinery. Regression context: without seeding, a window created while
    // AX is busy probes into the optimism grace (isStandard: false), gets
    // filtered out of Windows.all(), and the snapshot pumped in response to
    // its own create bang doesn't contain it — the create is silently
    // absorbed. All tests use fake pids (no real AX RPC fires on the cache-
    // hit path) and clean up via invalidate(pid:).

    test("WindowAddressabilityCache.confirm seeds a sticky-success verdict that survives past grace") {
        let pid: pid_t = 7_777_704
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 7_777_704,
                                          isStandard: true, isMinimized: false, now: 1000.0)
        let p = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_704, now: 1000.1)
        try expectEqual(p.addressable, true)
        try expectEqual(p.isStandard, true,
            "AX-confirmed standard verdict must win over grace's isStandard:false")
        // Far past the 5s grace — a probe-derived entry would have had to
        // re-probe (and fail, fake pid); the confirmed entry must stick.
        let late = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_704, now: 1100.0)
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
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_705, true, now: 1001.0)
        let minimized = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_705, now: 1001.1)
        try expectEqual(minimized.isMinimized, true)
        try expectEqual(minimized.isStandard, true, "setMinimized must not disturb isStandard")
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_705, false, now: 1002.0)
        let restored = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_705, now: 1002.1)
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
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 7_777_706, true, now: 1000.0)
        // Probe goes down the normal (unseeded) path: fake pid → grace
        // optimism with isStandard false, NOT a synthesized minimized entry.
        let p = WindowAddressabilityCache.probe(pid: pid, windowID: 7_777_706, now: 1000.1)
        try expectEqual(p.isMinimized, false,
            "setMinimized on an unknown key must not fabricate cache state")
        try expectEqual(p.isStandard, false)
    }

    // (TahoeSynthPoll + WindowEvents.tahoeMinimizeBang removed 2026-06-05:
    //  WindowsAXObserver now registers kAXWindowMiniaturizedNotification per
    //  window, which only fires on real Cmd+M — no tab-switch ambiguity to
    //  gate against. AX is the right primitive for this.)

    // MARK: - Batch — all-AX queued commit
    //
    // History being pinned: the original batch split one window's geometry
    // across two unsynchronized channels — size via AX at setFrame time,
    // position via SLSTransaction at commit — and each app's late resize
    // re-asserted its stale origin over the committed SLS move (2026-06-10:
    // windows stacked at old origins / offscreen). The rework queues FULL
    // frames and applies them all through the normal AX setFrame dance in
    // one main-thread burst at commit: one channel, no split, and begin no
    // longer depends on SkyLight tx symbols (it can't fail unless a batch
    // is already open).

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
        try expectEqual(WindowsByID.beginBatch(), true,
                        "begin must not depend on SkyLight symbols any more")
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
