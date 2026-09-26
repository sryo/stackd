import Foundation
import JavaScriptCore

/// Tests for the sd.display.forPoint / sd.display.forWindow helpers.
/// Pure JS: reads sd.display.all.peek() and walks the list. JSHarness shares
/// one JSContext across the whole run, so every test pushes its own display
/// list first rather than relying on the channel's prior state.
func registerDisplayHelpersTests() {
    let twoDisplays = """
    window.__sd_push("displays", [
      { displayID: 1, frame: { x: 0,    y: 0, w: 1920, h: 1080 } },
      { displayID: 2, frame: { x: 1920, y: 0, w: 1080, h: 1920 } }
    ]);
    """

    test("forPoint: empty display list returns null") {
        let out = JSHarness.evalString("""
        (function() {
          window.__sd_push("displays", []);
          return sd.display.forPoint(100, 100);
        })()
        """)
        try expectEqual(out, "null")
    }

    test("forPoint: returns the display containing the point") {
        let out = JSHarness.evalString("""
        (function() {
          \(twoDisplays)
          return [sd.display.forPoint(500, 500), sd.display.forPoint(2500, 500)]
            .map(d => d ? d.displayID : "null").join(",");
        })()
        """)
        try expectEqual(out, "1,2")
    }

    test("forPoint: shared edge belongs to the display on its right (half-open frames)") {
        // x = 1920 is display 1's right edge and display 2's left edge; with
        // [x, x+w) containment it must resolve to display 2, never both/none.
        let out = JSHarness.evalString("""
        (function() {
          \(twoDisplays)
          const d = sd.display.forPoint(1920, 10);
          return d ? d.displayID : "null";
        })()
        """)
        try expectEqual(out, "2")
    }

    test("forPoint: point outside all displays returns null") {
        let out = JSHarness.evalString("""
        (function() {
          \(twoDisplays)
          return sd.display.forPoint(5000, 5000);
        })()
        """)
        try expectEqual(out, "null")
    }

    test("forWindow: resolves by the window's center, not its origin") {
        // Origin (1800, 100) is on display 1; center (2000, 150) is on 2.
        let out = JSHarness.evalString("""
        (function() {
          \(twoDisplays)
          const d = sd.display.forWindow({ frame: { x: 1800, y: 100, w: 400, h: 100 } });
          return d ? d.displayID : "null";
        })()
        """)
        try expectEqual(out, "2")
    }

    test("forWindow: null / frameless input returns null") {
        let out = JSHarness.evalString("""
        (function() {
          \(twoDisplays)
          return [sd.display.forWindow(null), sd.display.forWindow({})].map(String).join(",");
        })()
        """)
        try expectEqual(out, "null,null")
    }
}
