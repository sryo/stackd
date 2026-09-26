import Foundation

// Tests for `ScrollClaim.decide` in Sources/DataSources/Input.swift — the
// synchronous decision the consuming tap makes for every scrollWheel event
// while a stack holds a claim (sd.events.claimScroll).
func registerScrollClaimTests() {

    // CGScrollPhase / CGMomentumScrollPhase raw values.
    let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, mayBegin: Int64 = 128
    let mBegin: Int64 = 1, mContinue: Int64 = 2, mEnd: Int64 = 3
    let trackpad: UInt64 = 0x1000_00abc, other: UInt64 = 0x1000_00def

    func ev(phase: Int64 = 0, momentum: Int64 = 0, continuous: Bool = true,
            sender: UInt64 = 0x1000_00abc) -> ScrollWheel.Fields {
        ScrollWheel.Fields(pointDeltaX: 0, pointDeltaY: 3, fixedDeltaX: 0, fixedDeltaY: 0.3,
                           phase: phase, momentumPhase: momentum,
                           isContinuous: continuous, senderId: sender)
    }

    test("ScrollClaim.decide: no claim passes everything") {
        try expectEqual(ScrollClaim.decide(claim: nil, ev(phase: changed)), .pass)
    }

    test("ScrollClaim.decide: swallows the claimed sender's changed, ended and momentum events") {
        let c = ScrollClaim(senderId: trackpad, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: changed)), .swallow)
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: ended)), .swallow)
        for m in [mBegin, mContinue, mEnd] {
            try expectEqual(ScrollClaim.decide(claim: c, ev(momentum: m)), .swallow, "momentum \(m)")
        }
    }

    test("ScrollClaim.decide: the next began from the claimed sender releases and passes") {
        let c = ScrollClaim(senderId: trackpad, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: began)), .release)
    }

    test("ScrollClaim.decide: mayBegin interleaved with the momentum tail keeps the claim") {
        let c = ScrollClaim(senderId: trackpad, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: mayBegin)), .swallow)
    }

    test("ScrollClaim.decide: phase-less continuous events from the claimed sender are swallowed") {
        let c = ScrollClaim(senderId: trackpad, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev()), .swallow)
    }

    test("ScrollClaim.decide: other senders and unattributed events pass") {
        let c = ScrollClaim(senderId: trackpad, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: changed, sender: other)), .pass)
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: began, sender: other)), .pass)
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: changed, sender: 0)), .pass)
    }

    test("ScrollClaim.decide: a wildcard claim takes any phased trackpad event, never a wheel") {
        let c = ScrollClaim(senderId: nil, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: changed, sender: other)), .swallow)
        try expectEqual(ScrollClaim.decide(claim: c, ev(momentum: mContinue, sender: 0)), .swallow)
        try expectEqual(ScrollClaim.decide(claim: c, ev(continuous: false, sender: other)), .pass)
        try expectEqual(ScrollClaim.decide(claim: c, ev(phase: began, sender: other)), .release)
    }

    test("ScrollClaim.decide: a sender-scoped claim never swallows a discrete wheel") {
        let c = ScrollClaim(senderId: trackpad, owner: "a")
        try expectEqual(ScrollClaim.decide(claim: c, ev(continuous: false)), .pass)
    }
}
