import Foundation
import CoreGraphics

// WindowResizeTracker — the pure state machine behind sd.window.resizing.
// Frames are fed per drained window-server frame event; `interacting` is
// the left-button gate, `isSelf` the FrameLedger echo verdict.
func registerWindowResizeTrackerTests() {
    typealias T = WindowResizeTracker
    let start = CGRect(x: 100, y: 100, width: 800, height: 600)

    func primed(_ id: UInt32 = 1, _ frame: CGRect = start) -> T {
        var t = T()
        _ = t.observe(id: id, frame: frame, interacting: false, isSelf: false, now: 0)
        return t
    }

    test("resize tracker: first size change with the button down begins from the prior frame") {
        var t = primed()
        let f = CGRect(x: 100, y: 100, width: 820, height: 600)
        let e = t.observe(id: 1, frame: f, interacting: true, isSelf: false, now: 1)
        try expectEqual(e?.phase, .began)
        try expectEqual(e?.frame, f)
        try expectEqual(e?.startFrame, start)
        try expectEqual(e?.edges, T.Edges(left: false, right: true, top: false, bottom: false))
    }

    test("resize tracker: later frames are changed, the start frame stays") {
        var t = primed()
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        let f = CGRect(x: 100, y: 100, width: 850, height: 600)
        let e = t.observe(id: 1, frame: f, interacting: true, isSelf: false, now: 2)
        try expectEqual(e?.phase, .changed)
        try expectEqual(e?.frame, f)
        try expectEqual(e?.startFrame, start)
    }

    test("resize tracker: an unchanged frame during a drag emits nothing") {
        var t = primed()
        let f = CGRect(x: 100, y: 100, width: 820, height: 600)
        _ = t.observe(id: 1, frame: f, interacting: true, isSelf: false, now: 1)
        try expectEqual(t.observe(id: 1, frame: f, interacting: true, isSelf: false, now: 2), nil)
    }

    test("resize tracker: release ends the drag at the frame read then") {
        var t = primed()
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        let final = CGRect(x: 100, y: 100, width: 900, height: 600)
        let out = t.release(frames: [1: final])
        try expectEqual(out.map(\.phase), [.ended])
        try expectEqual(out.first?.frame, final)
        try expectEqual(out.first?.startFrame, start)
        try expect(!t.isActive)
    }

    test("resize tracker: release without a readable frame ends at the last frame seen") {
        var t = primed()
        let f = CGRect(x: 100, y: 100, width: 820, height: 600)
        _ = t.observe(id: 1, frame: f, interacting: true, isSelf: false, now: 1)
        try expectEqual(t.release(frames: [:]).first?.frame, f)
    }

    test("resize tracker: a mouse-up with no size change emits nothing") {
        var t = primed()
        // A plain move with the button down: origin changes, size doesn't.
        try expectEqual(t.observe(id: 1, frame: start.offsetBy(dx: 40, dy: 0), interacting: true, isSelf: false, now: 1), nil)
        try expectEqual(t.release(frames: [1: start.offsetBy(dx: 40, dy: 0)]), [])
    }

    test("resize tracker: no button, no drag") {
        var t = primed()
        try expectEqual(t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: false, isSelf: false, now: 1), nil)
        try expect(!t.isActive)
    }

    test("resize tracker: a daemon echo does not begin a drag") {
        var t = primed()
        try expectEqual(t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: true, now: 1), nil)
        try expect(!t.isActive)
    }

    test("resize tracker: a window never seen before only primes the baseline") {
        var t = T()
        try expectEqual(t.observe(id: 1, frame: start, interacting: true, isSelf: false, now: 0), nil)
        try expectEqual(t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)?.phase, .began)
    }

    test("resize tracker: one active drag per window — no second began") {
        var t = primed()
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        let e = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 780, height: 600), interacting: true, isSelf: false, now: 2)
        try expectEqual(e?.phase, .changed)
        try expectEqual(t.activeIDs, [1])
    }

    test("resize tracker: a second window cannot begin while one drag is active") {
        var t = primed()
        _ = t.observe(id: 2, frame: CGRect(x: 900, y: 100, width: 400, height: 600), interacting: false, isSelf: false, now: 0)
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        // The neighbor a stack is writing, with an echo the ledger misses.
        try expectEqual(t.observe(id: 2, frame: CGRect(x: 920, y: 100, width: 380, height: 600), interacting: true, isSelf: false, now: 2), nil)
        try expectEqual(t.activeIDs, [1])
    }

    test("resize tracker: after release the next size change begins a new drag") {
        var t = primed()
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        _ = t.release(frames: [1: CGRect(x: 100, y: 100, width: 820, height: 600)])
        let e = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 700, height: 600), interacting: true, isSelf: false, now: 3)
        try expectEqual(e?.phase, .began)
        try expectEqual(e?.startFrame, CGRect(x: 100, y: 100, width: 820, height: 600))
    }

    test("resize tracker: quiet with the button up ends the drag; button still down keeps it") {
        var t = primed()
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        try expectEqual(t.expireQuiet(now: 1 + T.quietInterval + 0.01, interacting: true), [])
        try expectEqual(t.expireQuiet(now: 1 + T.quietInterval - 0.01, interacting: false), [])
        try expectEqual(t.expireQuiet(now: 1 + T.quietInterval + 0.01, interacting: false).map(\.phase), [.ended])
        try expect(!t.isActive)
    }

    test("resize tracker: forgetting a window drops its drag silently") {
        var t = primed()
        _ = t.observe(id: 1, frame: CGRect(x: 100, y: 100, width: 820, height: 600), interacting: true, isSelf: false, now: 1)
        t.forget(id: 1)
        try expect(!t.isActive)
        try expectEqual(t.release(frames: [:]), [])
    }

    test("resize edges: origin moved means the leading edge moved") {
        let left = CGRect(x: 80, y: 100, width: 820, height: 600)
        try expectEqual(T.edges(from: start, to: left), T.Edges(left: true, right: false, top: false, bottom: false))
        let top = CGRect(x: 100, y: 90, width: 800, height: 610)
        try expectEqual(T.edges(from: start, to: top), T.Edges(left: false, right: false, top: true, bottom: false))
        let bottomRight = CGRect(x: 100, y: 100, width: 830, height: 640)
        try expectEqual(T.edges(from: start, to: bottomRight), T.Edges(left: false, right: true, top: false, bottom: true))
        try expectEqual(T.edges(from: start, to: start), T.Edges(left: false, right: false, top: false, bottom: false))
    }

    test("resize event payload carries id, phase, frames and edges") {
        var t = primed(7)
        let e = t.observe(id: 7, frame: CGRect(x: 90, y: 100, width: 810, height: 600), interacting: true, isSelf: false, now: 1)!
        let p = e.payload
        try expectEqual(p["id"] as? Int, 7)
        try expectEqual(p["phase"] as? String, "began")
        try expectEqual((p["frame"] as? [String: Int])?["x"], 90)
        try expectEqual((p["startFrame"] as? [String: Int])?["w"], 800)
        try expectEqual((p["edges"] as? [String: Bool])?["left"], true)
        try expectEqual((p["edges"] as? [String: Bool])?["right"], false)
    }
}
