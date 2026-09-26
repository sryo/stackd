import Foundation
import JavaScriptCore

// Tests for the stack-side gesture physics in Runtime/src/26-gesture.js
// (sd.gesture.*), run in JSHarness's JSContext. The spring is driven by a
// fake ticker so frames are deterministic.
func registerGestureHelpersTests() {

    func num(_ expr: String) -> Double {
        JSHarness.context.evaluateScript(expr)?.toDouble() ?? .nan
    }
    func str(_ expr: String) -> String {
        JSHarness.evalString(expr) ?? "<nil>"
    }

    test("gesture.velocityTracker: constant motion reports its speed per second") {
        let v = num("""
        (() => { const vt = sd.gesture.velocityTracker();
          for (let t = 0; t <= 96; t += 8) vt.add(t, t * 0.5, -t);
          const v = vt.velocity(96); return v.x * 10000 + v.y; })()
        """)
        // x: 0.5 px/ms = 500/s, y: -1 px/ms = -1000/s
        try expect(abs(v - (500 * 10000 - 1000)) < 1, "got \(v)")
    }

    test("gesture.velocityTracker: only the trailing window counts") {
        let v = num("""
        (() => { const vt = sd.gesture.velocityTracker({ window: 100 });
          for (let t = 0; t < 400; t += 8) vt.add(t, t * 0.1);          // slow
          const x0 = 399 * 0.1;
          for (let t = 400; t <= 496; t += 8) vt.add(t, x0 + (t - 400) * 2); // fast
          return vt.velocity(496).x; })()
        """)
        try expect(abs(v - 2000) < 1, "got \(v)")
    }

    test("gesture.velocityTracker: window clamps to 80..150 ms") {
        let v = num("""
        (() => { const vt = sd.gesture.velocityTracker({ window: 1000 });
          for (let t = 0; t < 300; t += 10) vt.add(t, 0);
          for (let t = 300; t <= 450; t += 10) vt.add(t, (t - 300) * 1);
          return vt.velocity(450).x; })()
        """)
        try expect(abs(v - 1000) < 1, "a 1000 ms window would average in the rest; got \(v)")
    }

    test("gesture.velocityTracker: a finger held still before release has no velocity") {
        let v = str("""
        (() => { const vt = sd.gesture.velocityTracker();
          vt.add(0, 0); vt.add(10, 10);
          const late = vt.velocity(10 + 200).x;
          const one = sd.gesture.velocityTracker(); one.add(0, 5);
          return late + ',' + one.velocity(0).x; })()
        """)
        try expectEqual(v, "0,0")
    }

    test("gesture.rubberBand: passes through inside, resists past the edges") {
        try expectEqual(num("sd.gesture.rubberBand(50, 0, 100, 300)"), 50)
        let over = num("sd.gesture.rubberBand(200, 0, 100, 300)")
        try expect(abs(over - (100 + (1 - 1 / (100 * 0.55 / 300 + 1)) * 300)) < 1e-9, "got \(over)")
        let under = num("sd.gesture.rubberBand(-100, 0, 100, 300)")
        try expect(abs(under - (0 - (over - 100))) < 1e-9, "symmetric below min, got \(under)")
        let far = num("sd.gesture.rubberBand(1e9, 0, 100, 300)")
        try expect(far < 400 && far > 399, "approaches max + dimension, got \(far)")
    }

    test("gesture.project: 0.997/ms decay lands velocity·d/(1−d) ms ahead") {
        let p = num("sd.gesture.project(10, 1000)")
        try expect(abs(p - (10 + 0.997 / 0.003)) < 1e-6, "got \(p)")
        try expectEqual(num("sd.gesture.project(10, 0)"), 10)
    }

    test("gesture.snap: commits to the target nearest the projected release") {
        try expectEqual(num("sd.gesture.snap(100, 1000, [0, 400, 800])"), 400)
        try expectEqual(num("sd.gesture.snap(100, 0, [0, 400, 800])"), 0)
        try expectEqual(num("sd.gesture.snap(100, -1000, [0, 400, 800])"), 0)
        try expectEqual(num("sd.gesture.snap(100, 3000, [0, 400, 800])"), 800)
    }

    test("gesture.springStep: exact for any dt and never overshoots from rest") {
        try expectEqual(num("sd.gesture.springStep(0, 0, 1, 0.35, 0).value"), 0)
        let late = num("sd.gesture.springStep(0, 0, 1, 0.35, 5).value")
        try expect(abs(late - 1) < 1e-6, "settled, got \(late)")
        let monotone = str("""
        (() => { let s = { value: 0, velocity: 0 }, prev = -1;
          for (let i = 0; i < 120; i++) {
            s = sd.gesture.springStep(s.value, s.velocity, 1, 0.35, 1 / 60);
            if (s.value < prev - 1e-12 || s.value > 1 + 1e-12) return 'bad ' + i + ' ' + s.value;
            prev = s.value;
          }
          return 'ok'; })()
        """)
        try expectEqual(monotone, "ok")
        let oneStep = num("sd.gesture.springStep(0, 0, 1, 0.35, 0.1).value")
        let twoSteps = num("""
        (() => { const a = sd.gesture.springStep(0, 0, 1, 0.35, 0.05);
          return sd.gesture.springStep(a.value, a.velocity, 1, 0.35, 0.05).value; })()
        """)
        try expect(abs(oneStep - twoSteps) < 1e-12, "step size independent: \(oneStep) vs \(twoSteps)")
    }

    // Fake ticker: records the subscriber and whether it unsubscribed.
    let fakeTicker = """
    function __fakeTicker() {
      const t = { fn: null, unsubscribed: false,
        subscribe(fn) { t.fn = fn; fn(null); return () => { t.unsubscribed = true; }; },
        run(frames, dt) { for (let i = 0; i < frames && t.fn && !t.unsubscribed; i++) t.fn({ timestamp: 100 + i * dt }); } };
      return t;
    }
    """

    test("gesture.spring: runs on ticks to the target, completes and unsubscribes") {
        JSHarness.context.evaluateScript(fakeTicker)
        let out = str("""
        (() => { const tk = __fakeTicker(); let done = null, updates = 0;
          const s = sd.gesture.spring({ from: 0, to: 100, ticker: tk,
            onUpdate: () => updates++, onComplete: (v) => { done = v; } });
          tk.run(600, 1 / 60);
          return [done, s.value, s.running, tk.unsubscribed, updates > 10].join(','); })()
        """)
        try expectEqual(out, "100,100,false,true,true")
    }

    test("gesture.spring: stop() catches it mid-flight with value and velocity") {
        JSHarness.context.evaluateScript(fakeTicker)
        let out = str("""
        (() => { const tk = __fakeTicker(); let completed = false;
          const s = sd.gesture.spring({ from: 0, to: 100, ticker: tk, onComplete: () => { completed = true; } });
          tk.run(6, 1 / 60);
          const caught = s.stop();
          const frozen = s.value;
          tk.run(10, 1 / 60);
          return [caught.value > 0 && caught.value < 100, caught.velocity > 0,
                  s.value === frozen, completed, tk.unsubscribed].join(','); })()
        """)
        try expectEqual(out, "true,true,true,false,true")
    }

    test("gesture.spring: retarget keeps velocity and lands on the new target") {
        JSHarness.context.evaluateScript(fakeTicker)
        let out = str("""
        (() => { const tk = __fakeTicker(); let done = null;
          const s = sd.gesture.spring({ from: 0, to: 100, ticker: tk, onComplete: (v) => { done = v; } });
          tk.run(5, 1 / 60);
          const v = s.velocity;
          s.retarget(-50);
          const same = s.velocity === v;
          tk.run(600, 1 / 60);
          return [same, done].join(','); })()
        """)
        try expectEqual(out, "true,-50")
    }

    test("gesture.spring: defaults to sd.displayLink") {
        let out = str("""
        (() => { const s = sd.gesture.spring({ from: 0, to: 1 });
          const r = s.running; s.stop(); return r + ',' + s.running; })()
        """)
        try expectEqual(out, "true,false")
    }

    test("gesture.spring in stack source infers the displayLink permission") {
        let perms = ChannelInference.infer(from: "const s = sd.gesture.spring({ from: 0, to: 1 });")
        try expect(perms.contains("displayLink"), "got \(perms)")
        let none = ChannelInference.infer(from: "sd.gesture.rubberBand(x, 0, 1, 1);")
        try expect(!none.contains("displayLink"), "got \(none)")
    }
}
