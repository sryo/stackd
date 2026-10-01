import Foundation
import CoreGraphics

// Tests for the retarget repaint gate in Sources/DataSources/Overlay.swift.
//
// A retarget that resizes the panel, or lands it on another display (new
// backing scale), shows the previous target's border stretched over the new
// frame until the WebView repaints. The panel is held transparent from that
// retarget until the page confirms a painted frame (or a fallback fires).
// A same-size move on one display needs no repaint and never hides.
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

    test("OverlayScreens.retargetRepaints: a different size on the same display → true") {
        try expect(OverlayScreens.retargetRepaints(
            from: CGRect(x: 0, y: 0, width: 800, height: 600),
            to: CGRect(x: 900, y: 0, width: 700, height: 600),
            screens: [builtIn, external]))
    }

    test("OverlayScreens.retargetRepaints: same size, same display → false") {
        try expect(!OverlayScreens.retargetRepaints(
            from: CGRect(x: 0, y: 0, width: 800, height: 600),
            to: CGRect(x: 900, y: 100, width: 800, height: 600),
            screens: [builtIn, external]))
    }

    test("OverlayScreens.retargetRepaints: same size on another display → true") {
        try expect(OverlayScreens.retargetRepaints(
            from: CGRect(x: 0, y: 0, width: 800, height: 600),
            to: CGRect(x: 100, y: 1500, width: 800, height: 600),
            screens: [builtIn, external]))
    }

    test("OverlayScreens.retargetRepaints: first placement → false") {
        try expect(!OverlayScreens.retargetRepaints(
            from: .zero, to: CGRect(x: 0, y: 0, width: 800, height: 600),
            screens: [builtIn, external]))
    }

    test("OverlayRevealGate: a retarget that needs no repaint never hides") {
        var g = OverlayRevealGate()
        try expect(!g.retargeted(repaints: false))
        try expectEqual(g.confirmation(pushInFlight: false), nil)
    }

    test("OverlayRevealGate: a repainting retarget hides until its confirm lands") {
        var g = OverlayRevealGate()
        try expect(g.retargeted(repaints: true), "should hide")
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
        _ = g.retargeted(repaints: true)
        let old = g.confirmation(pushInFlight: false)!
        _ = g.retargeted(repaints: true)
        try expect(!g.confirmed(generation: old), "stale confirm must not reveal")
        let fresh = g.confirmation(pushInFlight: false)!
        try expect(g.confirmed(generation: fresh))
    }

    test("OverlayRevealGate: a no-repaint retarget while hidden keeps waiting") {
        var g = OverlayRevealGate()
        _ = g.retargeted(repaints: true)
        let old = g.confirmation(pushInFlight: false)!
        try expect(!g.retargeted(repaints: false), "already hidden; nothing new to hide")
        try expect(!g.confirmed(generation: old), "the new target hasn't painted yet")
        let fresh = g.confirmation(pushInFlight: false)!
        try expect(g.confirmed(generation: fresh))
    }

    test("OverlayRevealGate: fallback reveals a stuck confirm, once") {
        var h = OverlayRevealGate()
        _ = h.retargeted(repaints: true)
        let hg = h.hiddenGeneration!
        try expect(h.fallback(generation: hg), "fallback reveals")
        try expect(!h.fallback(generation: hg), "only once")
        try expectEqual(h.hiddenGeneration, nil)
    }
}
