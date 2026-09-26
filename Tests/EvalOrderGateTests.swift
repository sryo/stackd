import Foundation

// Tests for `EvalOrderGate` in `Sources/Bridge.swift` — when a script for a
// stack's WebView may be evaluated inline instead of hopping to main. Inline
// saves a main-queue hop per response/push/bang, but must never overtake a
// script that was queued earlier (an off-main push followed by an on-main
// response for the same stack keeps its order).

func registerEvalOrderGateTests() {
    test("EvalOrderGate runs inline on main with nothing queued") {
        var g = EvalOrderGate()
        try expect(g.shouldRunInline(isMain: true))
    }

    test("EvalOrderGate never runs inline off main") {
        var g = EvalOrderGate()
        try expect(!g.shouldRunInline(isMain: false))
    }

    test("EvalOrderGate queues behind an earlier queued script until it drains") {
        var g = EvalOrderGate()
        try expect(!g.shouldRunInline(isMain: false))      // A queued
        try expect(!g.shouldRunInline(isMain: true), "must not overtake the queued script")  // B queued
        g.drained()                                        // A ran; B still queued
        try expect(!g.shouldRunInline(isMain: true), "B is still queued")                     // C queued
        g.drained()                                        // B ran
        g.drained()                                        // C ran
        try expect(g.shouldRunInline(isMain: true), "nothing queued: inline again")
    }
}
