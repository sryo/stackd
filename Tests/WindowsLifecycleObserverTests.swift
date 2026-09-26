import CoreGraphics
import Foundation

/// Tests for the pure decisions behind the safety-backstop
/// `WindowsLifecycleObserver` poll: the snapshot diff (new key → created,
/// dropped key → destroyed, same key with a new title → titleChanged carrying
/// the OLD title), the bounded re-pump ladder, and which poll-detected
/// creates/destroys still fire. The observer's timer, CGWindowList read and
/// `axCoveredRecently` (which needs a live AX observer) are not exercised.
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
    // Pure core of the create/destroy → channel-consistency loop: re-pump
    // until the snapshot reflects the event, within a bounded ladder. The
    // scheduling around it (StackHost.verifyPump,
    // WindowLifecycleFanout.fireCreated) is not exercised here.

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

    // MARK: - pollCreateActions — suppressed creates still owe a channel pump
    //
    // The gates rightly suppress duplicate BANGS, but the wid still just
    // entered the poll snapshot — full heal-path story in the
    // pollCreateActions doc comment (Windows.swift).

    test("pollCreateActions: nothing suppressed → announce all, no pump nudge") {
        let created = [snap(id: 1, title: "A"), snap(id: 2, title: "B")]
        let r = WindowsLifecycleObserver.pollCreateActions(
            created: created, axCovered: { _ in false }, announced: { _ in false })
        try expectEqual(r.announce.map(\.id), [1, 2])
        try expectEqual(r.pumpNudge, false,
                        "fully-announced creates already pump via the fanout — no extra nudge")
    }

    test("pollCreateActions: ax-covered create is suppressed but still owed a pump nudge") {
        let created = [snap(id: 1, title: "A"), snap(id: 2, title: "B")]
        let r = WindowsLifecycleObserver.pollCreateActions(
            created: created, axCovered: { $0 == 2 }, announced: { _ in false })
        try expectEqual(r.announce.map(\.id), [1])
        try expectEqual(r.pumpNudge, true,
                        "the suppressed wid entered Windows.all() — the channel must still push")
    }

    test("pollCreateActions: already-announced create is suppressed but still owed a pump nudge") {
        let created = [snap(id: 7, title: "A")]
        let r = WindowsLifecycleObserver.pollCreateActions(
            created: created, axCovered: { _ in false }, announced: { $0 == 7 })
        try expect(r.announce.isEmpty)
        try expectEqual(r.pumpNudge, true)
    }

    test("pollCreateActions: empty diff → no announce, no nudge") {
        let r = WindowsLifecycleObserver.pollCreateActions(
            created: [], axCovered: { _ in true }, announced: { _ in true })
        try expect(r.announce.isEmpty)
        try expectEqual(r.pumpNudge, false, "an empty diff must not trigger pump churn every tick")
    }

    // MARK: - pollDestroyActions — only a reported destroy suppresses the poll's

    test("pollDestroyActions: a window that left Windows.all() fires destroy") {
        let gone = [snap(id: 1, title: "A"), snap(id: 2, title: "B")]
        let r = WindowsLifecycleObserver.pollDestroyActions(destroyed: gone, destroyReported: { _ in false })
        try expectEqual(r.map(\.id), [1, 2])
    }

    test("pollDestroyActions: a destroy AX or CGS already reported is not fired twice") {
        let gone = [snap(id: 1, title: "A"), snap(id: 2, title: "B")]
        let r = WindowsLifecycleObserver.pollDestroyActions(destroyed: gone, destroyReported: { $0 == 2 })
        try expectEqual(r.map(\.id), [1])
    }

    test("shouldSkipTick: an empty window list after a non-empty one is a transient read") {
        // CGWindowList can come back empty for a moment at wake; diffing it
        // would report every window destroyed and then re-created.
        try expect(WindowsLifecycleObserver.shouldSkipTick(previousCount: 5, currentCount: 0))
        try expect(!WindowsLifecycleObserver.shouldSkipTick(previousCount: 5, currentCount: 4))
        try expect(!WindowsLifecycleObserver.shouldSkipTick(previousCount: 0, currentCount: 0))
    }
}
