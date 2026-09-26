import Foundation
import CoreGraphics

// Tests for the pure halves of the window-server event follow path in
// `Sources/DataSources/Overlay.swift`: `OverlayFollowTargets` (which target
// wids overlays follow) and
// `OverlayFollowRoute` (what a 806/807 for a tracked target does: move the
// panel right there, hand off to the main-thread step, or nothing), plus
// `WindowFrameInterest` in Windows.swift (the connection-wide list).

func registerOverlayEventFollowTests() {
    // MARK: OverlayFollowTargets

    test("OverlayFollowTargets: first overlay on a wid changes the target set") {
        var t = OverlayFollowTargets<Int>()
        try expect(t.set(1, wid: 100))
        try expectEqual(t.wids, [100])
    }

    test("OverlayFollowTargets: a second overlay on the same wid, or a repeated set, leaves the set alone") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        try expect(!t.set(2, wid: 100))
        try expectEqual(t.wids, [100])
        try expect(!t.set(1, wid: 100), "re-setting the same target is not a change")
    }

    test("OverlayFollowTargets: retarget swaps the wid") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        try expect(t.set(1, wid: 200))
        try expectEqual(t.wids, [200])
    }

    test("OverlayFollowTargets: retarget away from a shared wid keeps it in the set") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        _ = t.set(2, wid: 100)
        try expect(t.set(1, wid: 200))
        try expectEqual(t.wids, [100, 200])
    }

    test("OverlayFollowTargets: wids are sorted and unique") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 300)
        _ = t.set(2, wid: 100)
        _ = t.set(3, wid: 300)
        try expectEqual(t.wids, [100, 300])
    }

    test("OverlayFollowTargets: removing the last overlay on a wid drops it") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        _ = t.set(2, wid: 100)
        try expect(!t.remove(1))
        try expect(t.remove(2))
        try expectEqual(t.wids, [])
    }

    test("OverlayFollowTargets: removing an unknown overlay is not a change") {
        var t = OverlayFollowTargets<Int>()
        try expect(!t.remove(9))
    }

    test("OverlayFollowTargets: a destroyed target drops every overlay on it") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        _ = t.set(2, wid: 100)
        _ = t.set(3, wid: 200)
        try expect(t.drop(wid: 100))
        try expectEqual(t.wids, [200])
        try expect(!t.drop(wid: 100))
    }

    test("OverlayFollowTargets: contains reflects the listed wids") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        try expect(t.contains(wid: 100))
        try expect(!t.contains(wid: 200))
    }

    // MARK: OverlayFollowRoute

    let entry = OverlayFollowEntry(wid: 100, panelWID: 7, outset: 4,
                                   targetSize: CGSize(width: 400, height: 300),
                                   visible: true)
    let same = CGRect(x: 50, y: 60, width: 400, height: 300)

    test("OverlayFollowRoute: a pure move of a visible target moves the panel now") {
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: entry, bounds: same),
                        .moveNow(CGPoint(x: 46, y: 56)))
    }

    test("OverlayFollowRoute: a move that also changed the size goes to main") {
        let grown = CGRect(x: 50, y: 60, width: 420, height: 300)
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: entry, bounds: grown),
                        .stepOnMain)
    }

    test("OverlayFollowRoute: sub-half-point size jitter still counts as a pure move") {
        let jitter = CGRect(x: 50, y: 60, width: 400.3, height: 299.8)
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: entry, bounds: jitter),
                        .moveNow(CGPoint(x: 46, y: 56)))
    }

    test("OverlayFollowRoute: resize always goes to main") {
        try expectEqual(OverlayFollowRoute.action(for: .resized(wid: 100), entry: entry, bounds: same),
                        .stepOnMain)
    }

    test("OverlayFollowRoute: a hidden panel goes to main (moving would not re-show it)") {
        var hidden = entry
        hidden.visible = false
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: hidden, bounds: same),
                        .stepOnMain)
    }

    test("OverlayFollowRoute: unreadable bounds go to main") {
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: entry, bounds: nil),
                        .stepOnMain)
    }

    test("OverlayFollowRoute: a panel never placed yet goes to main") {
        var unplaced = entry
        unplaced.panelWID = 0
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: unplaced, bounds: same),
                        .stepOnMain)
    }

    test("OverlayFollowRoute: a target under a daemon animation ignores window-server moves") {
        var commanded = entry
        commanded.commanded = true
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 100), entry: commanded, bounds: same),
                        .ignore)
        try expectEqual(OverlayFollowRoute.action(for: .resized(wid: 100), entry: commanded, bounds: same),
                        .ignore)
    }

    // MARK: OverlayFrameSource

    test("OverlayFrameSource: while animating the commanded frame wins and the live read is skipped") {
        var liveReads = 0
        let commanded = CGRect(x: 10, y: 20, width: 300, height: 200)
        let frame = OverlayFrameSource.targetFrame(commanded: commanded) {
            liveReads += 1
            return CGRect(x: 0, y: 0, width: 100, height: 100)
        }
        try expectEqual(frame, commanded)
        try expectEqual(liveReads, 0)
    }

    test("OverlayFrameSource: with no animation the live read is used") {
        let live = CGRect(x: 5, y: 6, width: 70, height: 80)
        try expectEqual(OverlayFrameSource.targetFrame(commanded: nil) { live }, live)
        try expectEqual(OverlayFrameSource.targetFrame(commanded: nil) { nil }, nil)
    }

    test("OverlayFollowRoute: events for another wid are ignored") {
        try expectEqual(OverlayFollowRoute.action(for: .moved(wid: 999), entry: entry, bounds: same),
                        .ignore)
    }

    test("OverlayFollowRoute: non-frame events are ignored") {
        try expectEqual(OverlayFollowRoute.action(for: .reordered(wid: 100), entry: entry, bounds: same),
                        .ignore)
        try expectEqual(OverlayFollowRoute.action(for: .destroyed(wid: 100), entry: entry, bounds: same),
                        .ignore)
    }

    test("OverlayFollowRoute.frameEventWID picks out 806/807 only") {
        try expectEqual(OverlayFollowRoute.frameEventWID(.moved(wid: 5)), 5)
        try expectEqual(OverlayFollowRoute.frameEventWID(.resized(wid: 6)), 6)
        try expectEqual(OverlayFollowRoute.frameEventWID(.reordered(wid: 7)), nil)
    }

    // MARK: WindowFrameInterest

    test("WindowFrameInterest: tracked windows and overlay targets, sorted, no duplicates") {
        try expectEqual(WindowFrameInterest.list(tracked: [30, 10, 20], targets: [20, 5]),
                        [5, 10, 20, 30])
        try expectEqual(WindowFrameInterest.list(tracked: [], targets: [42]), [42],
                        "an overlay target AX doesn't track is still listed")
    }

    // MARK: kill switch

    test("OverlayEventFollow.flagEnabled is on by default") {
        try expect(OverlayEventFollow.flagEnabled([:]))
        try expect(OverlayEventFollow.flagEnabled(["STACKD_OVERLAY_EVENTS": "1"]))
    }

    test("OverlayEventFollow.flagEnabled: STACKD_OVERLAY_EVENTS=0 is the kill switch") {
        try expect(!OverlayEventFollow.flagEnabled(["STACKD_OVERLAY_EVENTS": "0"]))
    }

    // MARK: stale entries

    test("OverlayFollowTargets.wid(for:) is nil once the target was destroyed") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        try expectEqual(t.wid(for: 1), 100)
        _ = t.drop(wid: 100)
        try expectEqual(t.wid(for: 1), nil)
    }

    test("OverlayFollowTargets.wid(for:) follows a retarget and forgets a detach") {
        var t = OverlayFollowTargets<Int>()
        _ = t.set(1, wid: 100)
        _ = t.set(1, wid: 200)
        try expectEqual(t.wid(for: 1), 200)
        _ = t.remove(1)
        try expectEqual(t.wid(for: 1), nil)
    }

    // MARK: off-main move already applied

    test("OverlayTickPlan: a move the event path already applied is skipped") {
        try expect(OverlayTickPlan.serverAlreadyAt(CGPoint(x: 46, y: 56),
                                                   applied: CGPoint(x: 46, y: 56)))
        try expect(OverlayTickPlan.serverAlreadyAt(CGPoint(x: 46.2, y: 55.8),
                                                   applied: CGPoint(x: 46, y: 56)))
    }

    test("OverlayTickPlan: a move to anywhere else still runs") {
        try expect(!OverlayTickPlan.serverAlreadyAt(CGPoint(x: 50, y: 56),
                                                    applied: CGPoint(x: 46, y: 56)))
        try expect(!OverlayTickPlan.serverAlreadyAt(CGPoint(x: 46, y: 56), applied: nil))
    }
}
