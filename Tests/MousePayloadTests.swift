import Foundation
import AppKit

/// Tests for `Display.forPoint(_ p:in displays:)` — the pure-helper variant
/// that drives `sd.mouse`'s display enrichment without touching NSScreen.
/// The live `Display.forPoint(_:)` overload (NSScreen-backed) is exercised
/// by integration; here we pin the lookup contract against synthetic
/// display layouts the way real multi-display setups vary.
func registerMousePayloadTests() {
    // Two-display layout used across most cases: primary at origin,
    // external 1512px to the right.
    let primary: [String: Any] = [
        "id": 1,
        "frame": ["x": 0, "y": 0, "w": 1512, "h": 982]
    ]
    let external: [String: Any] = [
        "id": 2,
        "frame": ["x": 1512, "y": 0, "w": 2560, "h": 1440]
    ]

    test("forPoint: point inside primary returns primary") {
        let d = Display.forPoint(CGPoint(x: 100, y: 100), in: [primary, external])
        try expectEqual(d?["id"] as? Int, 1)
    }

    test("forPoint: point inside external returns external") {
        let d = Display.forPoint(CGPoint(x: 2000, y: 100), in: [primary, external])
        try expectEqual(d?["id"] as? Int, 2)
    }

    test("forPoint: off-screen point returns nil") {
        let d = Display.forPoint(CGPoint(x: 10000, y: 10000), in: [primary, external])
        try expectEqual(d == nil, true)
    }

    test("forPoint: point on the seam (exact x=1512) lands on external (CGRect.contains)") {
        // CGRect.contains is inclusive on the leading edge, exclusive on the
        // trailing. So x=1512 is INSIDE external's frame [1512,4072) but
        // OUTSIDE primary's frame [0,1512). Documents the tie-breaking rule.
        let d = Display.forPoint(CGPoint(x: 1512, y: 100), in: [primary, external])
        try expectEqual(d?["id"] as? Int, 2)
    }

    test("forPoint: first match wins on overlapping displays") {
        // Real macOS arrangements never overlap, but if a future setup did,
        // we want the contract pinned — first hit in iteration order.
        let a: [String: Any] = ["id": 10, "frame": ["x": 0, "y": 0, "w": 100, "h": 100]]
        let b: [String: Any] = ["id": 20, "frame": ["x": 0, "y": 0, "w": 100, "h": 100]]
        let d = Display.forPoint(CGPoint(x: 50, y: 50), in: [a, b])
        try expectEqual(d?["id"] as? Int, 10)
    }

    test("forPoint: malformed frame (missing key) is skipped, not crashed") {
        let bad: [String: Any] = ["id": 99, "frame": ["x": 0, "y": 0, "w": 100 /* h missing */]]
        let d = Display.forPoint(CGPoint(x: 50, y: 50), in: [bad, primary])
        try expectEqual(d?["id"] as? Int, 1)
    }

    test("forPoint: returns the same shape sd.mouse will serialize (id + frame)") {
        // The mouse-push payload calls this exact helper. Shape contract
        // guards the JS-side `m.display.id` / `m.display.frame.w` reads.
        let d = Display.forPoint(CGPoint(x: 100, y: 100), in: [primary, external])
        try expectEqual(d?["id"] as? Int, 1)
        let frame = d?["frame"] as? [String: Int]
        try expectEqual(frame?["x"], 0)
        try expectEqual(frame?["y"], 0)
        try expectEqual(frame?["w"], 1512)
        try expectEqual(frame?["h"], 982)
    }
}
