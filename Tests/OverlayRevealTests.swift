import Foundation
import CoreGraphics

// Tests for the cross-display retarget gate in Sources/DataSources/Overlay.swift.
//
// A retarget that lands the panel on another display changes its backing
// scale; until the WebView repaints at the new scale, the compositor shows
// the previous target's border stretched over the new frame. The panel is
// held transparent from that retarget until the page confirms a painted
// frame (or a fallback fires). Same-display retargets never hide.
//
// NOT covered here: the confirm itself (a double requestAnimationFrame in
// the overlay page) and the visual result — runtime-verified by switching
// focus between displays of different scale.

private let builtIn  = CGRect(x: 0, y: 0, width: 1710, height: 1112)
private let external = CGRect(x: 77, y: 1112, width: 1080, height: 2560)

func registerOverlayRevealTests() {
    test("OverlayScreens.crossesScreens: same display → false") {
        try expect(!OverlayScreens.crossesScreens(
            from: CGRect(x: 0, y: 0, width: 800, height: 600),
            to: CGRect(x: 800, y: 300, width: 800, height: 600),
            screens: [builtIn, external]))
    }

    test("OverlayScreens.crossesScreens: other display → true") {
        try expect(OverlayScreens.crossesScreens(
            from: CGRect(x: 0, y: 0, width: 800, height: 600),
            to: CGRect(x: 77, y: 1500, width: 1080, height: 800),
            screens: [builtIn, external]))
    }

    test("OverlayScreens.crossesScreens: first placement (.zero) → false") {
        try expect(!OverlayScreens.crossesScreens(
            from: .zero, to: CGRect(x: 77, y: 1500, width: 1080, height: 800),
            screens: [builtIn, external]))
    }

    test("OverlayScreens.crossesScreens: a frame off every screen → false") {
        try expect(!OverlayScreens.crossesScreens(
            from: CGRect(x: -9999, y: -9999, width: 4, height: 4),
            to: CGRect(x: 0, y: 0, width: 800, height: 600),
            screens: [builtIn, external]))
    }

    test("OverlayRevealGate: same-display retarget never hides") {
        var g = OverlayRevealGate()
        try expect(!g.retargeted(crossedScreens: false))
        try expectEqual(g.confirmation(pushInFlight: false), nil)
    }

    test("OverlayRevealGate: cross-display retarget hides until its confirm lands") {
        var g = OverlayRevealGate()
        try expect(g.retargeted(crossedScreens: true), "should hide")
        try expectEqual(g.confirmation(pushInFlight: true), nil, "waits for the target push")
        guard let gen = g.confirmation(pushInFlight: false) else {
            throw Expectation(message: "expected a confirm once the push is idle")
        }
        try expectEqual(g.confirmation(pushInFlight: false), nil, "one confirm in flight")
        try expect(g.confirmed(generation: gen), "should reveal")
        try expect(!g.confirmed(generation: gen), "reveals once")
    }

    test("OverlayRevealGate: a newer retarget supersedes an older confirm") {
        var g = OverlayRevealGate()
        _ = g.retargeted(crossedScreens: true)
        let old = g.confirmation(pushInFlight: false)!
        _ = g.retargeted(crossedScreens: true)
        try expect(!g.confirmed(generation: old), "stale confirm must not reveal")
        let fresh = g.confirmation(pushInFlight: false)!
        try expect(g.confirmed(generation: fresh))
    }

    test("OverlayRevealGate: a same-display retarget while hidden keeps waiting") {
        var g = OverlayRevealGate()
        _ = g.retargeted(crossedScreens: true)
        let old = g.confirmation(pushInFlight: false)!
        try expect(!g.retargeted(crossedScreens: false), "already hidden; nothing new to hide")
        try expect(!g.confirmed(generation: old), "the new target hasn't painted yet")
        let fresh = g.confirmation(pushInFlight: false)!
        try expect(g.confirmed(generation: fresh))
    }

    test("OverlayRevealGate: fallback reveals a stuck confirm, once") {
        var h = OverlayRevealGate()
        _ = h.retargeted(crossedScreens: true)
        let hg = h.hiddenGeneration!
        try expect(h.fallback(generation: hg), "fallback reveals")
        try expect(!h.fallback(generation: hg), "only once")
        try expectEqual(h.hiddenGeneration, nil)
    }
}
