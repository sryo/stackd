import AppKit
import Foundation

/// Tests for `StackHost.anchorRect` — the pure geometry function that turns
/// a manifest anchor edge into an NSRect on a given visible frame. Extracted
/// from `frameFor` so it can be tested without instantiating NSScreen.
///
/// Each test uses a 1000×800 visible frame at origin (0, 0) for arithmetic
/// clarity (so midX=500, midY=400).
func registerAnchorTests() {
    let vf = NSRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: corner anchors

    test("anchor: top-right places window in top-right with insets") {
        let r = StackHost.anchorRect(edge: "top-right", w: 100, h: 50, insetX: 10, insetY: 20, visibleFrame: vf)
        try expectEqual(r.minX, 890)   // 1000 - 100 - 10
        try expectEqual(r.minY, 730)   // 800 - 50 - 20
        try expectEqual(r.width, 100)
        try expectEqual(r.height, 50)
    }
    test("anchor: top-left places window in top-left with insets") {
        let r = StackHost.anchorRect(edge: "top-left", w: 100, h: 50, insetX: 10, insetY: 20, visibleFrame: vf)
        try expectEqual(r.minX, 10)
        try expectEqual(r.minY, 730)
    }
    test("anchor: bottom-right places window in bottom-right with insets") {
        let r = StackHost.anchorRect(edge: "bottom-right", w: 100, h: 50, insetX: 10, insetY: 20, visibleFrame: vf)
        try expectEqual(r.minX, 890)
        try expectEqual(r.minY, 20)
    }
    test("anchor: bottom-left places window in bottom-left with insets") {
        let r = StackHost.anchorRect(edge: "bottom-left", w: 100, h: 50, insetX: 10, insetY: 20, visibleFrame: vf)
        try expectEqual(r.minX, 10)
        try expectEqual(r.minY, 20)
    }

    // MARK: horizontal-center anchors (new)

    test("anchor: bottom-center centers horizontally, inset from bottom") {
        let r = StackHost.anchorRect(edge: "bottom-center", w: 80, h: 80, insetX: 0, insetY: 40, visibleFrame: vf)
        try expectEqual(r.minX, 460)   // midX (500) - w/2 (40)
        try expectEqual(r.minY, 40)
        try expectEqual(r.width, 80)
        try expectEqual(r.height, 80)
    }
    test("anchor: top-center centers horizontally, inset from top") {
        let r = StackHost.anchorRect(edge: "top-center", w: 100, h: 50, insetX: 0, insetY: 20, visibleFrame: vf)
        try expectEqual(r.minX, 450)   // 500 - 50
        try expectEqual(r.minY, 730)   // 800 - 50 - 20
    }
    test("anchor: bottom-center ignores insetX (centered horizontally)") {
        // insetX is irrelevant for horizontal-center anchors; only insetY moves
        // the window. Documented in the public taxonomy.
        let r1 = StackHost.anchorRect(edge: "bottom-center", w: 80, h: 80, insetX: 0,   insetY: 40, visibleFrame: vf)
        let r2 = StackHost.anchorRect(edge: "bottom-center", w: 80, h: 80, insetX: 999, insetY: 40, visibleFrame: vf)
        try expectEqual(r1, r2)
    }

    // MARK: full-bleed edge anchors

    test("anchor: top edge stretches full width, h is thickness") {
        let r = StackHost.anchorRect(edge: "top", w: 80, h: 30, insetX: 99, insetY: 99, visibleFrame: vf)
        try expectEqual(r.minX, 0)
        try expectEqual(r.minY, 770)   // 800 - 30
        try expectEqual(r.width, 1000)
        try expectEqual(r.height, 30)
    }
    test("anchor: bottom edge stretches full width, h is thickness") {
        let r = StackHost.anchorRect(edge: "bottom", w: 80, h: 30, insetX: 99, insetY: 99, visibleFrame: vf)
        try expectEqual(r.minX, 0)
        try expectEqual(r.minY, 0)
        try expectEqual(r.width, 1000)
        try expectEqual(r.height, 30)
    }
    test("anchor: left edge stretches full height, w is thickness") {
        let r = StackHost.anchorRect(edge: "left", w: 40, h: 50, insetX: 0, insetY: 0, visibleFrame: vf)
        try expectEqual(r.minX, 0)
        try expectEqual(r.minY, 0)
        try expectEqual(r.width, 40)
        try expectEqual(r.height, 800)
    }
    test("anchor: right edge stretches full height, w is thickness") {
        let r = StackHost.anchorRect(edge: "right", w: 40, h: 50, insetX: 0, insetY: 0, visibleFrame: vf)
        try expectEqual(r.minX, 960)   // 1000 - 40
        try expectEqual(r.minY, 0)
        try expectEqual(r.width, 40)
        try expectEqual(r.height, 800)
    }

    // MARK: unknown / default

    test("anchor: unknown edge falls back to screen center") {
        let r = StackHost.anchorRect(edge: "nonsense", w: 200, h: 100, insetX: 99, insetY: 99, visibleFrame: vf)
        try expectEqual(r.minX, 400)   // 500 - 100
        try expectEqual(r.minY, 350)   // 400 - 50
    }

    // MARK: non-origin visible frame (multi-display case)

    test("anchor: bottom-center respects non-origin visible frame") {
        // External display at +1920 on the X axis, dock height shifts minY up by 80.
        let vf2 = NSRect(x: 1920, y: 80, width: 1000, height: 720)
        let r = StackHost.anchorRect(edge: "bottom-center", w: 80, h: 80, insetX: 0, insetY: 40, visibleFrame: vf2)
        try expectEqual(r.minX, 2380)  // 1920 + 500 - 40
        try expectEqual(r.minY, 120)   // 80 + 40
    }
}
