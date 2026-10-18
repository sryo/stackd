import Foundation
import JavaScriptCore

/// The `{ id, subscribe, stop }` handle every streaming sd.* call returns
/// (sd.spotlight.subscribe, sd.bonjour.browse, sd.speech.listen,
/// sd.camera.stream, sd.windows.stream). Its id arrives asynchronously, so
/// subscribe() and stop() must work on either side of the bind. Driven
/// through JSHarness with a stubbed postMessage; each evaluateScript step
/// ends with the microtask drain that lets a resolved request bind.
func registerStreamHandleTests() {
    let ctx = JSHarness.context

    /// Installs a recording postMessage and the five handle factories, each
    /// paired with its start / stop wire types and channel prefix.
    func begin(_ base: Int) {
        ctx.evaluateScript("""
        globalThis.__sh = {
          base: \(base),
          sent: [],
          real: window.webkit.messageHandlers.sd.postMessage,
          cases: [
            { make: () => sd.spotlight.subscribe({ predicate: "kMDItemFSName == 'x'" }),
              start: "spotlight.subscribe", stop: "spotlight.subscribe.stop", ch: "spotlight:subscribe:" },
            { make: () => sd.bonjour.browse("_http._tcp"),
              start: "bonjour.browse.start", stop: "bonjour.browse.stop", ch: "bonjour:browse:" },
            { make: () => sd.speech.listen({ locale: "en-US" }),
              start: "speech.listen.start", stop: "speech.listen.stop", ch: "speech:listen:" },
            { make: () => sd.camera.stream({ fps: 5 }),
              start: "camera.stream.start", stop: "camera.stream.stop", ch: "camera:stream:" },
            { make: () => sd.windows.stream(42, { fps: 5 }),
              start: "windows.stream.start", stop: "windows.stream.stop", ch: "windows:stream:" },
          ],
          // Answers the oldest unanswered request of `type`.
          answer(type, value) {
            for (const p of this.sent) {
              if (p.type === type && !p.answered) { p.answered = true; window.__sd_response(p.requestId, value); return; }
            }
          },
          id(i) { return this.base + i; },
          push(i, n) { window.__sd_push(this.cases[i].ch + this.id(i), { n: n }); },
          stops(i) { return this.sent.filter(p => p.type === this.cases[i].stop).map(p => p.id); },
        };
        window.webkit.messageHandlers.sd.postMessage = (p) => { __sh.sent.push(p); };
        """)
    }

    func end() {
        ctx.evaluateScript("window.webkit.messageHandlers.sd.postMessage = __sh.real;")
    }

    func json(_ expr: String) -> String? {
        ctx.evaluateScript("JSON.stringify(\(expr))")?.toString()
    }

    test("stream handle: a subscriber attached before the id binds gets every push after it") {
        begin(9100)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => {
          const r = { got: [], h: c.make() };
          r.h.subscribe((v) => { if (v) r.got.push(v.n); });
          return r;
        });
        __sh.cases.forEach((c, i) => __sh.answer(c.start, __sh.id(i)));
        """)
        ctx.evaluateScript("__sh.cases.forEach((c, i) => { __sh.push(i, 1); __sh.push(i, 2); });")
        try expectEqual(json("__sh.runs.map(r => r.h.id - __sh.base)"), "[0,1,2,3,4]")
        try expectEqual(json("__sh.runs.map(r => r.got)"), "[[1,2],[1,2],[1,2],[1,2],[1,2]]")
    }

    test("stream handle: an unsubscribe taken before the id binds still stops delivery after it") {
        begin(9200)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => {
          const r = { got: [], h: c.make() };
          r.unsub = r.h.subscribe((v) => { if (v) r.got.push(v.n); });
          return r;
        });
        __sh.cases.forEach((c, i) => __sh.answer(c.start, __sh.id(i)));
        """)
        ctx.evaluateScript("""
        __sh.cases.forEach((c, i) => { __sh.push(i, 1); __sh.runs[i].unsub(); __sh.push(i, 2); });
        """)
        try expectEqual(json("__sh.runs.map(r => r.got)"), "[[1],[1],[1],[1],[1]]")
    }

    test("stream handle: unsubscribing before the id binds means the subscriber never fires") {
        begin(9300)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => {
          const r = { got: [], h: c.make() };
          r.h.subscribe((v) => { if (v) r.got.push(v.n); })();
          return r;
        });
        __sh.cases.forEach((c, i) => __sh.answer(c.start, __sh.id(i)));
        """)
        ctx.evaluateScript("__sh.cases.forEach((c, i) => __sh.push(i, 1));")
        try expectEqual(json("__sh.runs.map(r => r.got)"), "[[],[],[],[],[]]")
    }

    test("stream handle: a subscriber attached after the bind can unsubscribe") {
        begin(9400)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => ({ got: [], h: c.make() }));
        __sh.cases.forEach((c, i) => __sh.answer(c.start, __sh.id(i)));
        """)
        ctx.evaluateScript("""
        __sh.cases.forEach((c, i) => {
          const r = __sh.runs[i];
          const unsub = r.h.subscribe((v) => { if (v) r.got.push(v.n); });
          __sh.push(i, 1); unsub(); __sh.push(i, 2);
        });
        """)
        try expectEqual(json("__sh.runs.map(r => r.got)"), "[[1],[1],[1],[1],[1]]")
    }

    test("stream handle: stop() after the bind releases the stream by its id") {
        begin(9500)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => ({ h: c.make() }));
        __sh.cases.forEach((c, i) => __sh.answer(c.start, __sh.id(i)));
        """)
        ctx.evaluateScript("__sh.runs.forEach((r) => r.h.stop());")
        ctx.evaluateScript("")
        try expectEqual(json("__sh.cases.map((c, i) => __sh.stops(i).map(id => id - __sh.base))"),
                        "[[0],[1],[2],[3],[4]]")
    }

    test("stream handle: stop() before the id binds releases the stream once the id arrives") {
        begin(9600)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => {
          const r = { h: c.make(), result: "pending" };
          r.h.stop().then((v) => { r.result = v; });
          return r;
        });
        __sh.cases.forEach((c, i) => __sh.answer(c.start, __sh.id(i)));
        """)
        ctx.evaluateScript("")
        try expectEqual(json("__sh.cases.map((c, i) => __sh.stops(i).map(id => id - __sh.base))"),
                        "[[0],[1],[2],[3],[4]]")
        try expectEqual(json("__sh.runs.map(r => r.h.id)"), "[null,null,null,null,null]")
    }

    test("stream handle: a start that fails resolves stop() false without a stop request") {
        begin(9700)
        defer { end() }
        ctx.evaluateScript("""
        __sh.runs = __sh.cases.map((c) => ({ h: c.make(), result: "pending" }));
        __sh.cases.forEach((c) => __sh.answer(c.start, null));
        """)
        ctx.evaluateScript("__sh.runs.forEach((r) => r.h.stop().then((v) => { r.result = v; }));")
        ctx.evaluateScript("")
        try expectEqual(json("__sh.runs.map(r => r.result)"), "[false,false,false,false,false]")
        try expectEqual(json("__sh.cases.map((c, i) => __sh.stops(i).length)"), "[0,0,0,0,0]")
    }
}
