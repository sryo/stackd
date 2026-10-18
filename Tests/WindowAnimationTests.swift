import Foundation
import CoreGraphics

// WindowAnimationWatch — pure core of the early "animating" signal. After a
// CGS 1327 (animation began) the watch samples every frame; a tracked window
// whose window-list size differs from SkyLight's own frame is mid-animation
// (the genie warps the listed bounds, never the window's own frame). The
// signal follows the warp: it ends on the first frame the sizes match again
// (deminimize), and bridges the window leaving the screen (minimize).
func registerWindowAnimationTests() {
    let own = CGRect(x: 100, y: 100, width: 800, height: 600)
    let W = WindowAnimationWatch.self

    test("isAnimating(listed:own:) — warped listed size means animating") {
        let warped = CGRect(x: 120, y: 300, width: 640, height: 420)
        try expect(WindowAnimationWatch.isAnimating(listed: warped, own: own))
    }

    test("isAnimating(listed:own:) — identical bounds are not animating") {
        try expect(!WindowAnimationWatch.isAnimating(listed: own, own: own))
    }

    test("isAnimating(listed:own:) — sub-point rounding is not animating") {
        let rounded = CGRect(x: 100, y: 100, width: 800.5, height: 599.5)
        try expect(!WindowAnimationWatch.isAnimating(listed: rounded, own: own))
    }

    test("isAnimating(listed:own:) — an origin-only difference is a move, not an animation") {
        let moved = own.offsetBy(dx: 40, dy: -30)
        try expect(!WindowAnimationWatch.isAnimating(listed: moved, own: own))
    }

    test("begin opens a watch for watchDuration; later begins extend it") {
        var w = WindowAnimationWatch()
        try expect(!w.isWatching(now: 0))
        try expect(w.begin(now: 10), "the first begin opens a watch")
        try expect(w.isWatching(now: 10 + W.watchDuration - 0.01))
        try expect(!w.isWatching(now: 10 + W.watchDuration))
        try expect(w.begin(now: 20), "a begin after the watch closed opens a new one")
        try expect(!w.begin(now: 20.2), "a begin inside an open watch only extends it")
        try expect(w.isWatching(now: 20.2 + W.watchDuration - 0.01))
    }

    test("sample announces a window once per animation") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        try expectEqual(w.sample(warped: [1], listed: [1, 2], now: 0.016), [1], "first sighting announces")
        try expectEqual(w.sample(warped: [1], listed: [1, 2], now: 0.032), [],
                        "later frames of the same animation stay quiet")
        try expectEqual(w.sample(warped: [1, 2], listed: [1, 2], now: 0.048), [2], "windows are independent")
    }

    test("a warped window reads animating; untouched windows don't") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1, 2], now: 0.016)
        try expect(w.isAnimating(1, now: 0.02))
        try expect(!w.isAnimating(2, now: 0.02))
    }

    test("deminimize: animating ends on the first frame the sizes match again — no sticky hold") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        var t = 0.016
        while t < 0.5 {
            _ = w.sample(warped: [1], listed: [1], now: t)
            try expect(w.isAnimating(1, now: t))
            t += 0.016
        }
        _ = w.sample(warped: [], listed: [1], now: t)
        try expect(!w.isAnimating(1, now: t), "sizes match: the overlay may come back this frame")
    }

    test("a missed sample doesn't end a warp early, but a stale one expires") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1], now: 0.1)
        try expect(w.isAnimating(1, now: 0.1 + W.freshness - 0.01))
        try expect(!w.isAnimating(1, now: 0.1 + W.freshness + 0.01))
        try expect(W.freshness < 0.2, "only bridges a couple of dropped frames")
    }

    test("minimize: a warped window leaving the screen stays animating across the hand-off") {
        // The genie ends with the window gone from the on-screen list; the
        // overlay must not flash back before SkyLight reports it ordered out.
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1], now: 0.5)
        _ = w.sample(warped: [], listed: [], now: 0.516)
        try expect(w.isAnimating(1, now: 0.516 + W.vanishHold - 0.01))
        try expect(!w.isAnimating(1, now: 0.516 + W.vanishHold + 0.01))
        try expect(W.vanishHold > W.freshness)
    }

    test("the watch keeps sampling while a window is still warped, past watchDuration") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        var t = 0.016
        while t < 0.9 {
            _ = w.sample(warped: [1], listed: [1], now: t)
            try expect(w.isWatching(now: t + 0.001), "still warped at \(t)")
            t += 0.016
        }
        _ = w.sample(warped: [], listed: [1], now: t)
        try expect(!w.isWatching(now: t + 0.001), "warp over and past watchDuration: stop sampling")
    }

    test("a window that never un-warps stops being sampled at the cap") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        var t = 0.016
        while t < W.maxWatch {
            _ = w.sample(warped: [1], listed: [1], now: t)
            t += 0.016
        }
        try expect(!w.isWatching(now: W.maxWatch + 0.001))
        try expect(W.maxWatch >= 1 && W.maxWatch <= 2)
    }

    test("stackd's own minimize reads animating before the warp shows, once") {
        var w = WindowAnimationWatch()
        try expect(w.expect(1, now: 0), "announce at the call")
        try expect(!w.expect(1, now: 0.01), "already announced")
        try expect(w.isWatching(now: 0.01), "sampling starts without waiting for 1327")
        _ = w.sample(warped: [], listed: [1], now: 0.016)
        try expect(w.isAnimating(1, now: 0.016), "unwarped frames before the genie starts don't end it")
        try expectEqual(w.sample(warped: [1], listed: [1], now: 0.05), [], "the warp isn't a second announcement")
        try expect(w.isAnimating(1, now: 0.05))
    }

    test("stackd's own minimize that never animates stops reading animating") {
        var w = WindowAnimationWatch()
        _ = w.expect(1, now: 0)
        try expect(!w.isAnimating(1, now: W.watchDuration + 0.01))
    }

    test("a window that animates again after its animation ended announces again") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1], listed: [1], now: 0.1)
        _ = w.sample(warped: [], listed: [1], now: 0.2)
        _ = w.begin(now: 3)
        try expectEqual(w.sample(warped: [1], listed: [1], now: 3.1), [1])
    }

    test("prune keeps animations still in progress") {
        // Dropping finished entries is bookkeeping only: isAnimating is
        // already time-gated, so what prune must not break is a live warp.
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [1, 2], listed: [1, 2], now: 0.1)
        _ = w.sample(warped: [2], listed: [2], now: 0.2)
        w.prune(now: 0.21)
        try expect(!w.isAnimating(1, now: 0.21))
        try expect(w.isAnimating(2, now: 0.21))
    }

    // MARK: - WindowAnimationFrame: one frame's window-list reading

    test("an animation frame reads the tracked windows plus the ones still animating, and no others") {
        var w = WindowAnimationWatch()
        _ = w.begin(now: 0)
        _ = w.sample(warped: [9], listed: [9], now: 0)
        try expectEqual(w.animating(now: 0.05), [9])
        try expectEqual(WindowAnimationFrame.ids(tracked: [3, 1], animating: w.animating(now: 0.05)), [1, 3, 9])
        try expectEqual(WindowAnimationFrame.ids(tracked: [1], animating: [1]), [1], "an id is read once")
        try expectEqual(w.animating(now: 0.5), [], "an expired sighting is not read")
    }

    test("an animation frame lists on-screen windows and warps only tracked app windows read on screen") {
        // Shaped like CoreGraphics' own: numbers arrive as NSNumber, and
        // kCGWindowIsOnscreen is present only for on-screen windows.
        func desc(_ wid: Int, listed: CGRect, onscreen: Bool = true,
                  layer: Int = Int(CGWindowLevelForKey(.normalWindow))) -> [String: Any] {
            var d: [String: Any] = [kCGWindowNumber as String: NSNumber(value: wid),
                                    kCGWindowLayer as String: NSNumber(value: layer),
                                    kCGWindowBounds as String: listed.dictionaryRepresentation]
            if onscreen { d[kCGWindowIsOnscreen as String] = kCFBooleanTrue }
            return d
        }
        let warp = CGRect(x: 120, y: 300, width: 640, height: 420)
        let descriptions = [
            desc(1, listed: warp),                        // tracked, warped
            desc(2, listed: own),                         // tracked, sizes match
            desc(3, listed: warp, onscreen: false),       // tracked, off screen
            desc(4, listed: warp),                        // animating, no longer tracked
            desc(5, listed: warp, layer: Int(CGWindowLevelForKey(.statusWindow))),
            desc(6, listed: warp),                        // tracked, own frame unreadable
        ]
        let frame = WindowAnimationFrame(descriptions: descriptions, tracked: [1, 2, 3, 5, 6]) { wid in
            wid == 6 ? nil : own
        }
        try expectEqual(frame.listed, [1, 2, 4, 5, 6])
        try expectEqual(Set(frame.warped.keys), [1])
        try expectEqual(frame.warped[1]?.own, own)
        try expectEqual(frame.warped[1]?.listed, warp)
    }

    test("WindowAnimationFrame.describe returns the window list's own rows for exactly the asked ids") {
        try expectEqual(WindowAnimationFrame.describe([]).count, 0)
        let onscreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let sample = Array(onscreen.prefix(3))
        let ids = sample.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        guard !ids.isEmpty else { return }   // no windows in this session to describe
        let described = WindowAnimationFrame.describe(ids)
        try expectEqual(Set(described.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }), Set(ids))
        for row in described {
            let wid = row[kCGWindowNumber as String] as? CGWindowID
            let listedRow = sample.first { $0[kCGWindowNumber as String] as? CGWindowID == wid }
            try expectEqual(row[kCGWindowLayer as String] as? Int, listedRow?[kCGWindowLayer as String] as? Int)
            try expectEqual(row[kCGWindowIsOnscreen as String] as? Bool, true)
        }
    }

    test("a window's own bounds come from the one SLSGetWindowBounds binding in WindowServerReads.swift") {
        // The animation watch compares the listed bounds against the same
        // read the overlay tick and live-resize tracking use, on the
        // connection that doesn't wait on stackd's own panel transactions.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var binders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hits = text.components(separatedBy: "SkyLight.sym(\"SLSGetWindowBounds\")").count - 1
            binders += Array(repeating: url.lastPathComponent, count: hits)
        }
        try expectEqual(binders, ["WindowServerReads.swift"])
    }
}
