import AppKit
import CoreGraphics
import Foundation

// Which display a window is on: `Display.largestOverlapDisplay` is
// hs.window:screen()'s rule (hs.screen.find(rect): the display holding the
// largest part of the frame, the nearest one when none overlaps), and
// `WindowDisplay.resolve` prefers the window server's own answer, a display
// UUID, over it. The window server is a pair of closures here, so nothing
// below asks SkyLight except the live decode check at the end.

private let left  = Display.Placement(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), uuid: "UUID-LEFT")
private let right = Display.Placement(id: 2, frame: CGRect(x: 1920, y: 0, width: 1080, height: 1920), uuid: "UUID-RIGHT")
private let pair = [left, right]

private func server(window: String? = nil, rect: String? = nil) -> WindowDisplay.WindowServer {
    WindowDisplay.WindowServer(displayForWindow: { _ in window }, displayForRect: { _ in rect })
}

func registerWindowDisplayTests() {
    test("largestOverlapDisplay: a window straddling two displays belongs to the one holding more of it") {
        // Top-left (1800, 100) is on the left display, but 300 of its 400
        // points of width are on the right one.
        let frame = CGRect(x: 1800, y: 100, width: 400, height: 300)
        try expectEqual(Display.largestOverlapDisplay(frame: frame, displays: pair), right)
    }

    test("largestOverlapDisplay: a window fully inside a display belongs to it") {
        let frame = CGRect(x: 2000, y: 500, width: 600, height: 400)
        try expectEqual(Display.largestOverlapDisplay(frame: frame, displays: pair), right)
        try expectEqual(Display.largestOverlapDisplay(frame: CGRect(x: 10, y: 10, width: 50, height: 50), displays: pair), left)
    }

    test("largestOverlapDisplay: an offscreen window belongs to the display whose center is nearest") {
        // Far below the left display, nowhere near the right one's center.
        let below = CGRect(x: 100, y: 3000, width: 200, height: 200)
        try expectEqual(Display.largestOverlapDisplay(frame: below, displays: pair), left)
        // Past the right display's right edge.
        let beyond = CGRect(x: 4000, y: 900, width: 200, height: 200)
        try expectEqual(Display.largestOverlapDisplay(frame: beyond, displays: pair), right)
    }

    test("largestOverlapDisplay: an equal split goes to the display listed first") {
        let frame = CGRect(x: 1820, y: 100, width: 200, height: 100)
        try expectEqual(Display.largestOverlapDisplay(frame: frame, displays: pair), left)
        try expectEqual(Display.largestOverlapDisplay(frame: frame, displays: [right, left]), right)
    }

    test("largestOverlapDisplay: a zero-size frame still lands on the display it sits on") {
        let frame = CGRect(x: 2500, y: 1500, width: 0, height: 0)
        try expectEqual(Display.largestOverlapDisplay(frame: frame, displays: pair), right)
    }

    test("largestOverlapDisplay: no displays, no answer") {
        try expect(Display.largestOverlapDisplay(frame: CGRect(x: 0, y: 0, width: 10, height: 10), displays: []) == nil)
    }

    test("WindowDisplay.resolve: the window server's display for the window wins over the overlap rule") {
        // Overlap says right; the window server files the window under left.
        let frame = CGRect(x: 1800, y: 100, width: 400, height: 300)
        let got = WindowDisplay.resolve(windowID: 42, frame: frame, displays: pair,
                                        windowServer: server(window: "UUID-LEFT", rect: "UUID-RIGHT"))
        try expectEqual(got, left)
    }

    test("WindowDisplay.resolve: UUIDs match whatever their letter case") {
        let got = WindowDisplay.resolve(windowID: 42, frame: CGRect(x: 10, y: 10, width: 10, height: 10),
                                        displays: pair, windowServer: server(window: "uuid-right"))
        try expectEqual(got, right)
    }

    test("WindowDisplay.resolve: an unmatched window answer falls back to the window server's best display for the frame") {
        // "Main" is the identifier SkyLight uses when it has no per-display
        // answer; it names no display here.
        let frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        let got = WindowDisplay.resolve(windowID: 42, frame: frame, displays: pair,
                                        windowServer: server(window: "Main", rect: "UUID-RIGHT"))
        try expectEqual(got, right)
    }

    test("WindowDisplay.resolve: with no usable window-server answer the overlap rule decides") {
        let frame = CGRect(x: 1800, y: 100, width: 400, height: 300)
        try expectEqual(WindowDisplay.resolve(windowID: 42, frame: frame, displays: pair,
                                              windowServer: server(window: "Main", rect: "Main")), right)
        try expectEqual(WindowDisplay.resolve(windowID: 42, frame: frame, displays: pair,
                                              windowServer: server()), right)
        try expectEqual(WindowDisplay.resolve(windowID: 42, frame: frame, displays: pair,
                                              windowServer: nil), right)
    }

    test("WindowDisplay.resolve: a window without an id skips the per-window query") {
        var askedForWindow = false
        let ws = WindowDisplay.WindowServer(displayForWindow: { _ in askedForWindow = true; return "UUID-LEFT" },
                                            displayForRect: { _ in "UUID-RIGHT" })
        let got = WindowDisplay.resolve(windowID: nil, frame: CGRect(x: 10, y: 10, width: 10, height: 10),
                                        displays: pair, windowServer: ws)
        try expectEqual(got, right)
        try expect(!askedForWindow)
    }

    test("WindowDisplay.resolve: a single display needs no window-server query") {
        var asked = false
        let ws = WindowDisplay.WindowServer(displayForWindow: { _ in asked = true; return nil },
                                            displayForRect: { _ in asked = true; return nil })
        let got = WindowDisplay.resolve(windowID: 42, frame: CGRect(x: 9000, y: 9000, width: 10, height: 10),
                                        displays: [left], windowServer: ws)
        try expectEqual(got, left)
        try expect(!asked)
    }

    test("Windows.decode: every listed window carries a { id, frame } display, offscreen ones included") {
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let rows = Windows.decode(raw) { _, _ in
            WindowAddressabilityCache.Probe(addressable: true, isStandard: true, isMinimized: false, ts: 0)
        }
        let ids = Set(Display.placements().map { Int($0.id) })
        for row in rows {
            guard let display = row["display"] as? [String: Any] else {
                throw Expectation(message: "no display on \(row["id"] ?? "?")")
            }
            try expect(ids.contains(display["id"] as? Int ?? -1), "unknown display \(display)")
            try expect(display["frame"] is [String: Int], "frame shape: \(display)")
        }
    }
}
