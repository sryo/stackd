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
//      public, no-prompt read. The test process runs on a real macOS host,
//      so the inventory is non-empty in practice, and we can characterize
//      the dict contract (id / app / pid / title / onscreen / frame{x,y,w,h})
//      that JS consumers depend on without depending on which specific
//      windows are open.
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
//   - `WindowsByID.beginBatch` / `commitBatch` — would open an SLSTransaction
//     and (if any setFrame fired) mutate user windows on commit.
//   - `WindowsByID.snapshot` — exercises the SkyLight HW-capture SPI; safe
//     to read but environment-dependent (depends on which windows exist).
//   - The CGS event callback (`windowEventsCallback`) and the
//     `WindowsLifecycleObserver` timer loop — both are wire-into-WindowServer
//     state with no isolatable surface.
//
// Pattern mirrors AppsTests + MenubarItemsTests: pure helpers get the full
// table-driven treatment; AX-coupled readers get negative-input contract
// pinning so the JS-visible return type stays deterministic.

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

    test("Windows.all returns non-empty list with the documented per-entry keys") {
        // On any live macOS host, at least the Dock / Finder / WindowServer
        // helper produce normal-layer windows, so the list is never empty.
        // We characterize the dict contract every consumer depends on.
        let entries = Windows.all()
        try expect(!entries.isEmpty, "expected ≥1 window from CGWindowList, got 0")
        guard let first = entries.first else {
            throw Expectation(message: "no windows enumerated")
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
        for entry in Windows.all() {
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
        // double-count the same window.
        let ids = Windows.all().compactMap { $0["id"] as? Int }
        try expect(!ids.isEmpty, "no ids extracted from Windows.all")
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

    // MARK: - WindowsByID.setFrameProbed — return-shape contract

    test("WindowsByID.setFrameProbed for an unaddressable windowID returns ok:false, actual:NSNull") {
        // Probed variant must always return a dict with both keys so the JS
        // shape stays stable. When the underlying element isn't reachable
        // (windowID never existed, app quit), ok is false and actual is
        // NSNull — not missing. JS-side destructuring of
        //   const { ok, actual } = await sd.windows.setFrameProbed(id, frame)
        // would otherwise blow up with `actual is undefined`.
        let r = WindowsByID.setFrameProbed(windowID: 0, x: 0, y: 0, w: 100, h: 100)
        try expect(r["ok"] != nil, "ok key missing")
        try expect(r["actual"] != nil, "actual key missing (must be NSNull, not absent)")
        try expectEqual(r["ok"] as? Bool, false)
        try expect(r["actual"] is NSNull,
                   "actual should be NSNull for an unaddressable id, got \(type(of: r["actual"]!))")
    }

    test("WindowsByID.setFrameProbed actual frame, when present, exposes the x/y/w/h key set") {
        // Shape contract: when AX yields back a frame, it MUST contain all
        // four keys with Double values (matches sd.windows.frame's contract).
        // We can't force a real window in tests; skip the body if no window
        // is reachable. The unaddressable-id test above covers the failure
        // branch.
        let r = WindowsByID.setFrameProbed(windowID: 0, x: 0, y: 0, w: 100, h: 100)
        guard let actual = r["actual"] as? [String: Any] else { return }
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
}
