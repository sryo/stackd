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

    test("sd.windows.animating routes sd.window.animating with both frames") {
        let out = JSHarness.evalString("""
        (function() {
          let seen = null;
          sd.windows.animating.subscribe((d) => { if (d && d.id === 9) seen = d; });
          window.onBang_sd_window_animating({ id: 9,
            frame: {x:0,y:0,w:800,h:600}, visualFrame: {x:20,y:400,w:300,h:200} });
          return seen ? (seen.frame.w + ',' + seen.visualFrame.w) : 'null';
        })()
        """)
        try expectEqual(out, "800,300")
    }

    test("sd.windows.resizing routes sd.window.resizing with phase, frames and edges") {
        let out = JSHarness.evalString("""
        (function() {
          const seen = [];
          sd.windows.resizing.subscribe((d) => { if (d && d.id === 11) seen.push(d.phase); });
          const base = { id: 11, frame: {x:0,y:0,w:820,h:600}, startFrame: {x:0,y:0,w:800,h:600},
                         edges: {left:false,right:true,top:false,bottom:false} };
          for (const phase of ['began','changed','ended'])
            window.onBang_sd_window_resizing(Object.assign({}, base, { phase }));
          return seen.join(',');
        })()
        """)
        try expectEqual(out, "began,changed,ended")
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
