import Foundation
import CoreGraphics

// Tests for the pure halves of the window-server event follow path:
// `OverlayFollowTargets` (which target wids overlays follow), which events
// `OverlayEventFollow` takes, `OverlayFrameSource` (commanded vs live
// frame), plus `WindowFrameInterest` in WindowEvents.swift (the
// connection-wide list).

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

    test("OverlayEventFollow.frameEventWID picks out 806/807 only") {
        try expectEqual(OverlayEventFollow.frameEventWID(.moved(wid: 5)), 5)
        try expectEqual(OverlayEventFollow.frameEventWID(.resized(wid: 6)), 6)
        try expectEqual(OverlayEventFollow.frameEventWID(.reordered(wid: 7)), nil)
        try expectEqual(OverlayEventFollow.frameEventWID(.destroyed(wid: 8)), nil)
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
}
