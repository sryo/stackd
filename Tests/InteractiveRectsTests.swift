import AppKit
import Foundation

/// Pure-logic tests for the sd-on:click daemon side: body parsing and the
/// viewport→global coordinate flip. The impure remainder (EventTapRegistry
/// observer install, live click-through flipping) needs a running daemon +
/// real eventtap and is covered by the example-stack live check instead.
func registerInteractiveRectsTests() {
    test("parseInteractiveRects: valid rects parse in order") {
        let body: [String: Any] = ["rects": [
            ["x": 10.0, "y": 20.0, "w": 50.0, "h": 30.0],
            ["x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0],
        ]]
        let parsed = StackWindow.parseInteractiveRects(body)
        try expectEqual(parsed?.count, 2)
        try expectEqual(parsed?[0], CGRect(x: 10, y: 20, width: 50, height: 30))
        try expectEqual(parsed?[1], CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    test("parseInteractiveRects: empty array is valid (clears the gate)") {
        let parsed = StackWindow.parseInteractiveRects(["rects": [[String: Any]]()])
        try expectEqual(parsed?.isEmpty, true)
    }

    test("parseInteractiveRects: missing rects key is nil") {
        try expectEqual(StackWindow.parseInteractiveRects([:]) == nil, true)
    }

    test("parseInteractiveRects: non-finite coordinate is nil") {
        let body: [String: Any] = ["rects": [["x": Double.infinity, "y": 0.0, "w": 5.0, "h": 5.0]]]
        try expectEqual(StackWindow.parseInteractiveRects(body) == nil, true)
    }

    test("parseInteractiveRects: zero or negative size is nil") {
        let zero: [String: Any] = ["rects": [["x": 0.0, "y": 0.0, "w": 0.0, "h": 5.0]]]
        let neg: [String: Any] = ["rects": [["x": 0.0, "y": 0.0, "w": 5.0, "h": -1.0]]]
        try expectEqual(StackWindow.parseInteractiveRects(zero) == nil, true)
        try expectEqual(StackWindow.parseInteractiveRects(neg) == nil, true)
    }

    test("screenRects: viewport rect lands at panel top-left + CSS offset in CG coords") {
        // Panel in AppKit coords (origin bottom-left, y up): x=100, y=100,
        // 400×300 on a primary display whose frame.maxY is 900. The panel's
        // top edge in CG coords (origin top-left, y down) is 900 - (100+300)
        // = 500. A CSS-viewport rect at (10, 20) is 10 right of the panel's
        // left edge and 20 below its top edge.
        let global = StackWindow.screenRects(
            viewport: [CGRect(x: 10, y: 20, width: 50, height: 30)],
            panelFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            primaryMaxY: 900)
        try expectEqual(global, [CGRect(x: 110, y: 520, width: 50, height: 30)])
    }

    test("screenRects: panel at the very top of the primary display") {
        // AppKit y + height == primaryMaxY → CG top edge is 0.
        let global = StackWindow.screenRects(
            viewport: [CGRect(x: 0, y: 0, width: 10, height: 10)],
            panelFrame: CGRect(x: 0, y: 876, width: 200, height: 24),
            primaryMaxY: 900)
        try expectEqual(global, [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }

    test("screenRects: negative-x panel (display left of primary) preserves offsets") {
        let global = StackWindow.screenRects(
            viewport: [CGRect(x: 5, y: 5, width: 20, height: 20)],
            panelFrame: CGRect(x: -1440, y: 500, width: 300, height: 200),
            primaryMaxY: 900)
        try expectEqual(global, [CGRect(x: -1435, y: 205, width: 20, height: 20)])
    }
}
