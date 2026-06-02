import Foundation
import JavaScriptCore

/// Tests for sd.windows.{created, destroyed, moved, resized, minimized,
/// deminimized} channel sugar. Wraps the sd.window.* bang dispatch in a
/// subscribe-able signal so stack authors stop writing onBang_sd_window_*
/// handlers by hand.
func registerWindowChannelTests() {
    test("sd.windows.created — fires .value when window.onBang_sd_window_created dispatches") {
        let out = JSHarness.evalString("""
        (function() {
          let seen = null;
          sd.windows.created.subscribe((d) => { seen = d; });
          // Simulate the daemon's bang dispatch — Bridge calls
          // window.onBang_sd_window_created(payload).
          window.onBang_sd_window_created({ id: 42, app: "Calc" });
          return seen ? (seen.id + ',' + seen.app) : 'null';
        })()
        """)
        try expectEqual(out, "42,Calc")
    }

    test("sd.windows.destroyed — channel routes its own bang") {
        // Signals re-fire their cached value to new subscribers, and the
        // JSContext is shared across tests so prior dispatches may have
        // primed sd.windows.created. We only assert .destroyed updates
        // when its OWN bang fires — that's the property the sugar provides.
        let out = JSHarness.evalString("""
        (function() {
          let dCount = 0, lastD = null;
          sd.windows.destroyed.subscribe((v) => {
            // Skip the replay of any prior cached value.
            if (v && v.id === 7) { dCount++; lastD = v; }
          });
          window.onBang_sd_window_destroyed({ id: 7 });
          return dCount + ',' + (lastD ? lastD.id : 'null');
        })()
        """)
        try expectEqual(out, "1,7")
    }

    test("sd.windows.{moved,resized,minimized,deminimized} all exist as channels") {
        let out = JSHarness.evalString("""
        ['moved','resized','minimized','deminimized']
          .map(n => typeof sd.windows[n].subscribe)
          .join(',')
        """)
        try expectEqual(out, "function,function,function,function")
    }

    test("subscribe receives subsequent dispatches (not just the first)") {
        let out = JSHarness.evalString("""
        (function() {
          let count = 0;
          sd.windows.moved.subscribe((d) => { if (d) count++; });
          window.onBang_sd_window_moved({ id: 1, frame: {x:0,y:0,w:100,h:100} });
          window.onBang_sd_window_moved({ id: 1, frame: {x:50,y:0,w:100,h:100} });
          window.onBang_sd_window_moved({ id: 2, frame: {x:0,y:0,w:100,h:100} });
          return count;
        })()
        """)
        try expectEqual(out, "3")
    }
}
