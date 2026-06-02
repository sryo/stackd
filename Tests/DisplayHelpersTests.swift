import Foundation
import JavaScriptCore

/// Tests for the sd.display.forPoint / sd.display.forWindow helpers.
/// Pure JS: reads sd.display.all.peek() and walks the list. Lifted out of
/// 5+ verbatim per-stack reimplementations of the same containment loop.
func registerDisplayHelpersTests() {
    test("forPoint: empty display list returns null") {
        let out = JSHarness.evalString("""
        (function() {
          // No prior displays push → peek returns undefined.
          sd.display.all.subscribe(() => {}); // no-op subscribe to keep channel alive
          return sd.display.forPoint(100, 100);
        })()
        """)
        try expectEqual(out, "null")
    }

    test("forPoint: point inside primary display returns that display") {
        let out = JSHarness.evalString("""
        (function() {
          // Simulate a daemon push by invoking the channel's internal __sd_push.
          window.__sd_push("displays", [
            { displayID: 1, frame: { x: 0,    y: 0, w: 1920, h: 1080 } },
            { displayID: 2, frame: { x: 1920, y: 0, w: 1080, h: 1920 } }
          ]);
          const d = sd.display.forPoint(500, 500);
          return d ? d.displayID : "null";
        })()
        """)
        try expectEqual(out, "1")
    }

    test("forPoint: point inside secondary display returns that display") {
        let out = JSHarness.evalString("""
        (function() {
          window.__sd_push("displays", [
            { displayID: 1, frame: { x: 0,    y: 0, w: 1920, h: 1080 } },
            { displayID: 2, frame: { x: 1920, y: 0, w: 1080, h: 1920 } }
          ]);
          const d = sd.display.forPoint(2500, 500);
          return d ? d.displayID : "null";
        })()
        """)
        try expectEqual(out, "2")
    }

    test("forPoint: point outside all displays returns null") {
        let out = JSHarness.evalString("""
        (function() {
          window.__sd_push("displays", [
            { displayID: 1, frame: { x: 0, y: 0, w: 1920, h: 1080 } }
          ]);
          return sd.display.forPoint(5000, 5000);
        })()
        """)
        try expectEqual(out, "null")
    }

    test("forWindow: object with .frame returns the display under its center") {
        let out = JSHarness.evalString("""
        (function() {
          window.__sd_push("displays", [
            { displayID: 1, frame: { x: 0,    y: 0, w: 1920, h: 1080 } },
            { displayID: 2, frame: { x: 1920, y: 0, w: 1080, h: 1920 } }
          ]);
          // Window straddling? Use center: x + w/2, y + h/2.
          const win = { frame: { x: 1800, y: 100, w: 200, h: 100 } };
          // center.x = 1900 (still on display 1)
          const d = sd.display.forWindow(win);
          return d ? d.displayID : "null";
        })()
        """)
        try expectEqual(out, "1")
    }

    test("forPoint + forWindow: exported on sd.display") {
        let out = JSHarness.evalString("""
        typeof sd.display.forPoint + ',' + typeof sd.display.forWindow
        """)
        try expectEqual(out, "function,function")
    }
}
