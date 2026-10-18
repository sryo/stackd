import Foundation
import JavaScriptCore

// Tests for `EvalOutbox` (Sources/BridgeOutbox.swift): the scripts a stack's
// page is owed, queued in send order and handed over as one script per
// run-loop turn, plus the batch script's dispatch in a real runtime.

/// A fresh runtime with recorders for every kind of send.
private func recordingRuntime() throws -> JSContext {
    guard let ctx = JSHarness.makeContext() else { throw Expectation(message: "runtime failed to load") }
    ctx.exceptionHandler = { _, _ in }
    ctx.evaluateScript("""
    var log = [];
    sd.battery.subscribe(function (v) { if (v) log.push('push:' + v.percent); });
    window.onBang_ping = function (d) { log.push('bang:' + d.n); };
    window.onBang_boom = function () { throw new Error('boom'); };
    globalThis.probeCallback = function (a, b) { log.push('global:' + a + b); };
    var probeRequest = nextRequestId;
    request({ type: 'probe' }).then(function (v) { log.push('resp:' + v); });
    """)
    return ctx
}

private func sends(requestId: Int) -> [String] {
    [
        Bridge.pushScript(channel: "battery", json: #"{"percent":1}"#),
        Bridge.responseScript(requestId: requestId, json: #""ok""#),
        Bridge.bangScript(name: "boom", json: "{}"),
        Bridge.bangScript(name: "ping", json: #"{"n":2}"#),
        Bridge.globalScript(handler: "probeCallback", args: ["1", #""x""#]),
        Bridge.pushScript(channel: "battery", json: #"{"percent":3}"#),
    ]
}

func registerEvalOutboxTests() {
    // ── the outbox model ─────────────────────────────────────────────────

    test("outbox: a burst of sends before the flush is taken as one script, in send order") {
        let box = EvalOutbox()
        try expect(box.append("log.push(1);"), "the first send schedules the flush")
        try expect(!box.append("log.push(2);"), "later sends ride the scheduled flush")
        try expect(!box.append("log.push(3);"))
        let script = box.take()
        try expectEqual(box.take(), nil, "everything went out in the one script")
        let ctx = JSContext()!
        ctx.evaluateScript("var log = [];")
        ctx.evaluateScript(script ?? "")
        try expectEqual(ctx.evaluateScript("log.join(',')")?.toString(), "1,2,3")
    }

    test("outbox: a send made while a flush is under way lands in the next flush") {
        let box = EvalOutbox()
        _ = box.append("a();")
        let first = box.take()
        try expect(box.append("b();"), "the outbox went idle at the take, so this schedules a new flush")
        try expectEqual(first, "a();")
        try expectEqual(box.take(), "b();")
    }

    test("outbox: a lone send goes out as exactly the script that was sent") {
        let box = EvalOutbox()
        let script = Bridge.pushScript(channel: "battery", json: "{}")
        _ = box.append(script)
        try expectEqual(box.take(), script)
    }

    test("outbox: a throwing script in a batch doesn't stop the ones after it") {
        let box = EvalOutbox()
        _ = box.append("log.push(1);")
        _ = box.append("throw new Error('x');")
        _ = box.append("log.push(3);")
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, _ in }
        ctx.evaluateScript("var log = []; var setTimeout = function () {};")
        ctx.evaluateScript(box.take() ?? "")
        try expectEqual(ctx.evaluateScript("log.join(',')")?.toString(), "1,3")
    }

    test("outbox: sends from many threads keep each thread's order and schedule one flush") {
        let box = EvalOutbox()
        let lock = NSLock()
        var schedules = 0
        DispatchQueue.concurrentPerform(iterations: 4) { t in
            for i in 0..<200 where box.append("log.push([\(t),\(i)]);") {
                lock.lock(); schedules += 1; lock.unlock()
            }
        }
        try expectEqual(schedules, 1)
        let ctx = JSContext()!
        ctx.evaluateScript("var log = [];")
        ctx.evaluateScript(box.take() ?? "")
        let ordered = ctx.evaluateScript("""
        [0,1,2,3].every(function (t) {
          var seen = log.filter(function (e) { return e[0] === t; }).map(function (e) { return e[1]; });
          return seen.length === 200 && seen.every(function (v, i) { return v === i; });
        })
        """)?.toBool()
        try expectEqual(ordered, true)
    }

    // ── the batch in a real runtime ──────────────────────────────────────

    test("outbox: a batch dispatches pushes, responses, bangs and callbacks as single scripts do") {
        let single = try recordingRuntime()
        let rid = Int(single.evaluateScript("probeRequest")!.toInt32())
        for script in sends(requestId: rid) { single.evaluateScript(script) }

        let batched = try recordingRuntime()
        let box = EvalOutbox()
        for script in sends(requestId: rid) { _ = box.append(script) }
        batched.evaluateScript(box.take() ?? "")

        let syncLog = "log.filter(function (e) { return e.indexOf('resp:') !== 0; }).join(',')"
        try expectEqual(batched.evaluateScript(syncLog)?.toString(), "push:1,bang:2,global:1x,push:3")
        try expectEqual(batched.evaluateScript(syncLog)?.toString(), single.evaluateScript(syncLog)?.toString())
        try expectEqual(batched.evaluateScript("log.filter(function (e) { return e === 'resp:ok'; }).length")?.toInt32(), 1)
        try expectEqual(single.evaluateScript("log.filter(function (e) { return e === 'resp:ok'; }).length")?.toInt32(), 1)
    }

    test("outbox: a response's promise continuation runs after the rest of its batch") {
        // One script is one task: microtasks queued by an early item run
        // once the whole batch has run, not between items.
        let batched = try recordingRuntime()
        let rid = Int(batched.evaluateScript("probeRequest")!.toInt32())
        let box = EvalOutbox()
        for script in sends(requestId: rid) { _ = box.append(script) }
        batched.evaluateScript(box.take() ?? "")
        try expectEqual(batched.evaluateScript("log.join(',')")?.toString(),
                        "push:1,bang:2,global:1x,push:3,resp:ok")
    }
}
