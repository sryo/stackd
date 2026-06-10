import CoreGraphics
import Foundation

/// Pure-diff tests for the safety-backstop `WindowsLifecycleObserver.diff`.
///
/// The observer itself is impure (CGWindowListCopyWindowInfo + Timer +
/// stderr logging), but the create / destroy / titleChanged classification
/// is pure key-set math we can unit-test in isolation. Slice 2 of the
/// 2026-06-05 window-events rework extracted the diff out of `tick()` so
/// the math could be locked here — without coupling tests to the live
/// macOS state the observer otherwise runs against.
///
/// We pin the contract behavior, not the implementation:
///   - new key in `next` → created
///   - dropped key in `prev` → destroyed
///   - same key + changed title → titleChanged with the OLD title
///   - same key + same title → nothing emitted
///
/// `axCoveredRecently` (Slice 4's missed-by-ax gate) lives on the observer
/// instance and reads `WindowsAXObserver.shared.lastAxFire`, which needs a
/// live AX-observer install — that path is verified manually per the plan's
/// Slice 6 ("user is ground truth" per memory feedback_user_confirms_fixed).
func registerWindowsLifecycleObserverTests() {

    func snap(id: Int, title: String, pid: Int = 100, app: String = "App", frame: CGRect = .zero)
        -> WindowsLifecycleObserver.Snap
    {
        WindowsLifecycleObserver.Snap(id: id, pid: pid, app: app, title: title, frame: frame)
    }

    test("diff: equal snapshots emit nothing") {
        // The hot path. Most ticks should hit this — between 10s polls
        // most windows are stable, so the diff is empty and `tick()`
        // doesn't bother the missed-by-ax check at all.
        let s: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "A"),
            2: snap(id: 2, title: "B"),
        ]
        let result = WindowsLifecycleObserver.diff(prev: s, next: s)
        try expect(result.created.isEmpty, "no creates")
        try expect(result.destroyed.isEmpty, "no destroys")
        try expect(result.titleChanged.isEmpty, "no title changes")
    }

    test("diff: new id in next is reported as created") {
        // The drift case AX is supposed to catch first — if the poll sees
        // a brand-new wid, the AX path should already have fired for it
        // within the last 12s. If it hasn't, `tick()` logs `missed-by-ax`.
        let prev: [Int: WindowsLifecycleObserver.Snap] = [1: snap(id: 1, title: "A")]
        let next: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "A"),
            2: snap(id: 2, title: "B"),
        ]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expectEqual(result.created.count, 1)
        try expectEqual(result.created.first?.id, 2)
        try expect(result.destroyed.isEmpty)
        try expect(result.titleChanged.isEmpty)
    }

    test("diff: dropped id in next is reported as destroyed with PREVIOUS snap") {
        // Destroy fires the PREVIOUS snap (last seen by the poll) because
        // the window is already gone — userland can't query its title /
        // frame anymore. Pin the snap-identity so the AppDelegate destroy
        // handler still has pid/app for WindowAddressabilityCache
        // invalidation.
        let oldSnap = snap(id: 5, title: "Doomed", pid: 42, app: "Safari")
        let prev: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "A"),
            5: oldSnap,
        ]
        let next: [Int: WindowsLifecycleObserver.Snap] = [1: snap(id: 1, title: "A")]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expect(result.created.isEmpty)
        try expectEqual(result.destroyed.count, 1)
        try expectEqual(result.destroyed.first?.id, 5)
        try expectEqual(result.destroyed.first?.app, "Safari",
            "destroyed snap must preserve app/pid from prev for cache invalidation")
        try expect(result.titleChanged.isEmpty)
    }

    test("diff: same id with changed title yields titleChanged with OLD title") {
        // The titleChanged tuple is (newSnap, oldTitle). AppDelegate sets
        // detail["oldTitle"] = oldTitle so stack authors can render
        // before/after transitions; that pairing is the reason we don't
        // just emit the new snap.
        let prev: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "Before"),
        ]
        let next: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "After"),
        ]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expect(result.created.isEmpty)
        try expect(result.destroyed.isEmpty)
        try expectEqual(result.titleChanged.count, 1)
        try expectEqual(result.titleChanged.first?.0.title, "After",
            "first tuple element is the new snap")
        try expectEqual(result.titleChanged.first?.1, "Before",
            "second tuple element is the OLD title (for detail[\"oldTitle\"])")
    }

    test("diff: title change without id change does not fire create/destroy") {
        // Regression guard — a previous draft tried to "re-create" the
        // window on title change. Bang authors expect titleChanged for
        // title flips, not destroyed+created.
        let prev: [Int: WindowsLifecycleObserver.Snap] = [1: snap(id: 1, title: "A")]
        let next: [Int: WindowsLifecycleObserver.Snap] = [1: snap(id: 1, title: "B")]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expect(result.created.isEmpty)
        try expect(result.destroyed.isEmpty)
        try expectEqual(result.titleChanged.count, 1)
    }

    test("diff: simultaneous create + destroy + title change all surface") {
        // Pathological-but-real case: the user Cmd-Q'd one app, opened
        // another, and renamed a third's window between two 10s poll
        // ticks. All three must surface — the missed-by-ax filter is
        // applied per-snap by the caller, not at the diff layer.
        let prev: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "Stable"),
            2: snap(id: 2, title: "Doomed", app: "Quit"),
            3: snap(id: 3, title: "OldName"),
        ]
        let next: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "Stable"),
            3: snap(id: 3, title: "NewName"),
            4: snap(id: 4, title: "FreshlyOpened"),
        ]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expectEqual(result.created.count, 1)
        try expectEqual(result.created.first?.id, 4)
        try expectEqual(result.destroyed.count, 1)
        try expectEqual(result.destroyed.first?.id, 2)
        try expectEqual(result.titleChanged.count, 1)
        try expectEqual(result.titleChanged.first?.0.id, 3)
        try expectEqual(result.titleChanged.first?.1, "OldName")
    }

    test("diff: empty prev (cold start) emits every next id as created") {
        // First tick after `install()` seeds `snapshot = current()` BEFORE
        // starting the timer, so this case only fires if a future refactor
        // breaks the seed. Guard against that — without the seed, every
        // startup would flood `onCreate` for every existing window.
        let prev: [Int: WindowsLifecycleObserver.Snap] = [:]
        let next: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "A"),
            2: snap(id: 2, title: "B"),
        ]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expectEqual(result.created.count, 2)
        try expect(result.destroyed.isEmpty)
        try expect(result.titleChanged.isEmpty)
    }

    test("diff: empty next (everything closed) emits every prev id as destroyed") {
        // Inverse of cold-start. If a user closes every window between two
        // polls, every prev id surfaces as destroyed. The bang fan-out
        // hits the missed-by-ax filter per-snap, so AX-covered ids drop
        // out before reaching userland.
        let prev: [Int: WindowsLifecycleObserver.Snap] = [
            1: snap(id: 1, title: "A"),
            2: snap(id: 2, title: "B"),
        ]
        let next: [Int: WindowsLifecycleObserver.Snap] = [:]
        let result = WindowsLifecycleObserver.diff(prev: prev, next: next)
        try expect(result.created.isEmpty)
        try expectEqual(result.destroyed.count, 2)
        try expect(result.titleChanged.isEmpty)
    }

    // MARK: - WindowsPumpRetry: the bounded sd.windows.all re-pump decision
    //
    // Pure core of the create/destroy → channel-consistency loop. The
    // scheduling around it (DispatchQueue.asyncAfter in StackHost.verifyPump
    // and WindowLifecycleFanout.fireCreated) is impure and verified live;
    // these tests pin the decision math so a refactor can't silently turn
    // "retry until the snapshot reflects the event" into "fire once and
    // hope" — which was the exact bug: a created window absent from the
    // pumped CGWindowList snapshot was dropped until the next focus event.

    test("pumpRetry: .present satisfied only when the wid is in the snapshot") {
        try expect(WindowsPumpRetry.satisfied(ids: [1, 2, 3], expectation: .present(2)),
                   "wid in snapshot must satisfy .present")
        try expect(!WindowsPumpRetry.satisfied(ids: [1, 3], expectation: .present(2)),
                   "wid missing from snapshot must NOT satisfy .present (CG lag — keep retrying)")
        try expect(!WindowsPumpRetry.satisfied(ids: [], expectation: .present(2)),
                   "empty snapshot must not satisfy .present")
    }

    test("pumpRetry: .absent satisfied only when the wid left the snapshot") {
        try expect(WindowsPumpRetry.satisfied(ids: [1, 3], expectation: .absent(2)),
                   "wid gone from snapshot must satisfy .absent")
        try expect(!WindowsPumpRetry.satisfied(ids: [1, 2, 3], expectation: .absent(2)),
                   "wid still listed must NOT satisfy .absent (CGWindowList keeps dead wids for a beat)")
        try expect(WindowsPumpRetry.satisfied(ids: [], expectation: .absent(2)),
                   "empty snapshot trivially satisfies .absent")
    }

    test("pumpRetry: ladder is bounded, in-range attempts get a delay, out-of-range get nil") {
        for attempt in 0..<WindowsPumpRetry.delays.count {
            try expect(WindowsPumpRetry.delay(attempt: attempt) != nil,
                       "attempt \(attempt) should have a delay")
        }
        try expect(WindowsPumpRetry.delay(attempt: WindowsPumpRetry.delays.count) == nil,
                   "ladder must exhaust — an unbounded retry loop here is polling-as-primary")
        try expect(WindowsPumpRetry.delay(attempt: -1) == nil,
                   "negative attempt must not crash or return a delay")
    }

    test("pumpRetry: cumulative ladder covers the documented CGWindowList lag ceiling") {
        // The observed CG lag is ~50–500ms. If a refactor trims the ladder
        // below that, the retry stops covering the very race it exists for
        // — and the symptom (created windows silently missing from the
        // channel) returns without any test failing. Pin the floor.
        let total = WindowsPumpRetry.delays.reduce(0, +)
        try expect(total >= 0.5,
                   "cumulative retry budget \(total)s no longer covers the 500ms CGWindowList lag ceiling")
        try expect(total <= 2.0,
                   "cumulative retry budget \(total)s drifts toward poll-as-primary; keep it tight")
    }
}
