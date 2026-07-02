import Foundation
import CoreGraphics

// FrameLedger — the daemon-side record of "frames WE wrote", powering two
// verdicts: `isSelf` (is this moved/resized notification an echo of our own
// write?) and `verify` (did the app honor the frame, snap it to a learnable
// grid quantum, or terminally refuse it?).
func registerFrameLedgerTests() {
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    test("observed frame near a recent write classifies as self") {
        let l = FrameLedger()
        l.recordWrite(windowID: 1, frame: rect(100, 100, 800, 600), now: 10.0)
        try expect(l.isSelf(windowID: 1, observed: rect(100, 100, 800, 600), now: 10.3, animating: false), "exact echo")
        try expect(l.isSelf(windowID: 1, observed: rect(105, 98, 792, 611), now: 10.3, animating: false), "echo within tolerance")
    }

    test("foreign frames and stale echoes classify as external") {
        let l = FrameLedger()
        l.recordWrite(windowID: 1, frame: rect(100, 100, 800, 600), now: 10.0)
        try expect(!l.isSelf(windowID: 1, observed: rect(400, 100, 800, 600), now: 10.2, animating: false), "user moved it 300px")
        try expect(!l.isSelf(windowID: 1, observed: rect(100, 100, 800, 600), now: 12.0, animating: false), "echo TTL expired")
        try expect(!l.isSelf(windowID: 2, observed: rect(100, 100, 800, 600), now: 10.1, animating: false), "never-written window")
    }

    test("active animation classifies everything on that window as self") {
        let l = FrameLedger()
        try expect(l.isSelf(windowID: 3, observed: rect(0, 0, 1, 1), now: 0, animating: true), "animating = ours by construction")
    }

    test("verify converges on an honored frame and within a learned quantum") {
        let l = FrameLedger()
        let target = rect(0, 0, 800, 600)
        try expectEqual(l.verify(windowID: 4, target: target, observed: target), FrameLedger.Verdict.converged)
        // Terminal-style cell rounding: first mismatch earns a retry…
        try expectEqual(l.verify(windowID: 4, target: target, observed: rect(0, 0, 793, 596)), .retry)
        // …the retry still mismatches by the same grid → learn the quantum,
        // report converged (grid-snapping is not refusal).
        try expectEqual(l.verify(windowID: 4, target: target, observed: rect(0, 0, 793, 596)), .converged)
        // Subsequent writes within the learned quantum converge first try.
        try expectEqual(l.verify(windowID: 4, target: rect(0, 0, 400, 300), observed: rect(0, 0, 396, 297)), .converged)
    }

    test("verify reports refusal beyond the learnable quantum") {
        let l = FrameLedger()
        let target = rect(0, 0, 800, 600)
        let clamped = rect(0, 0, 232, 231) // Calculator-style fixed size
        try expectEqual(l.verify(windowID: 5, target: target, observed: clamped), .retry)
        try expectEqual(l.verify(windowID: 5, target: target, observed: clamped), .refused)
    }

    test("refusal verdict tracks the observed frame for echo classification") {
        let l = FrameLedger()
        let target = rect(0, 0, 800, 600)
        let clamped = rect(0, 0, 232, 231)
        _ = l.verify(windowID: 6, target: target, observed: clamped)
        _ = l.verify(windowID: 6, target: target, observed: clamped)
        // The app's own clamp echo must classify as self — WE caused it.
        try expect(l.isSelf(windowID: 6, observed: clamped, now: 0.1, animating: false), "clamp echo is ours")
    }

    test("retry budget resets after convergence") {
        let l = FrameLedger()
        let target = rect(0, 0, 500, 500)
        try expectEqual(l.verify(windowID: 7, target: target, observed: rect(0, 0, 300, 300)), .retry)
        try expectEqual(l.verify(windowID: 7, target: target, observed: target), .converged)
        // Fresh mismatch on a later pass earns a fresh retry.
        try expectEqual(l.verify(windowID: 7, target: target, observed: rect(0, 0, 300, 300)), .retry)
    }

    test("write generation bumps per write, per window, and resets on clear") {
        // The probe's stale-retry guard: a deferred verification captures
        // the generation after its own write and must see it unchanged
        // before re-applying — any newer write means its target is stale.
        let l = FrameLedger()
        try expectEqual(l.generation(windowID: 9), 0)
        l.recordWrite(windowID: 9, frame: rect(0, 0, 1, 1), now: 0)
        let g1 = l.generation(windowID: 9)
        l.recordWrite(windowID: 9, frame: rect(5, 5, 1, 1), now: 0.01)
        try expect(l.generation(windowID: 9) > g1, "second write must bump")
        try expectEqual(l.generation(windowID: 10), 0, "windows must not couple")
        l.clear(windowID: 9)
        try expectEqual(l.generation(windowID: 9), 0, "clear resets")
    }

    test("clear drops all per-window state") {
        let l = FrameLedger()
        l.recordWrite(windowID: 8, frame: rect(1, 1, 2, 2), now: 0)
        _ = l.verify(windowID: 8, target: rect(0, 0, 800, 600), observed: rect(0, 0, 793, 596))
        l.clear(windowID: 8)
        try expect(!l.isSelf(windowID: 8, observed: rect(1, 1, 2, 2), now: 0.1, animating: false), "lastApplied must be gone")
        try expectEqual(l.verify(windowID: 8, target: rect(0, 0, 800, 600), observed: rect(0, 0, 793, 596)), .retry, "retry budget must be fresh")
    }
}
