import Foundation
import WebKit

// Every Bridge send into a stack's page — channel pushes, responses, bangs,
// callback fires, screen updates — queues in the stack's EvalOutbox and
// reaches the page in call order, one script per run-loop turn.

/// Replaces the page's push / response / bang / fs-event receivers with
/// recorders that log into one sequence; each also logs from a microtask,
/// which tells separate scripts (microtasks run between them) from one
/// batch (microtasks run after it).
private func installSequenceRecorder(_ page: BridgedPage) {
    _ = page.eval("""
    window.__seq = [];
    function __rec(tag) {
      window.__seq.push(tag);
      Promise.resolve().then(function () { window.__seq.push('~' + tag); });
    }
    window.__sd_push = function (name) { __rec('push:' + name); };
    window.__sd_response = function (id) { __rec('resp:' + id); };
    window.onBang_ping = function () { __rec('bang'); };
    window.__sd_fs_event = function (id) { __rec('fs:' + id); };
    0
    """)
}

private func sequence(_ page: BridgedPage, count: Int) -> String? {
    page.waitFor("window.__seq.length >= \(count) ? window.__seq.join(',') : ''", seconds: 10)
}

private func bridgeSources() throws -> [(name: String, text: String)] {
    let names = try FileManager.default.contentsOfDirectory(atPath: "Sources")
        .filter { $0.hasPrefix("Bridge") && $0.hasSuffix(".swift") }
        .sorted()
    return try names.map { ($0, try String(contentsOfFile: "Sources/" + $0, encoding: .utf8)) }
}

func registerBridgeSendOrderTests() {
    test("bridge sends: a burst in one turn reaches the page as one script") {
        let page = try BridgedPage()
        installSequenceRecorder(page)
        page.bridge.push(channel: "a", json: "1")
        page.bridge.push(channel: "b", json: "2")
        page.bridge.respond(requestId: 7, value: true)
        try expectEqual(sequence(page, count: 6), "push:a,push:b,resp:7,~push:a,~push:b,~resp:7")
    }

    test("bridge sends: sends in separate turns reach the page as separate scripts") {
        let page = try BridgedPage()
        installSequenceRecorder(page)
        page.bridge.push(channel: "a", json: "1")
        try expectEqual(sequence(page, count: 2), "push:a,~push:a")
        page.bridge.push(channel: "b", json: "2")
        try expectEqual(sequence(page, count: 4), "push:a,~push:a,push:b,~push:b")
    }

    test("bridge sends: call order holds across pushes, responses, bangs, callbacks and other threads") {
        let page = try BridgedPage()
        installSequenceRecorder(page)
        let bridge = page.bridge
        bridge.push(channel: "a", json: "1")
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            bridge.push(channel: "b", json: "2")
            sent.signal()
        }
        sent.wait()
        bridge.respond(requestId: 7, value: true)
        bridge.fireBang(name: "ping", detail: [:])
        bridge.dispatchFsEvents(watchId: 3, events: [])
        bridge.push(channel: "c", json: "3")
        let got = try sequence(page, count: 12).map { $0.split(separator: ",").filter { !$0.hasPrefix("~") }.joined(separator: ",") }
        try expectEqual(got, "push:a,push:b,resp:7,bang,fs:3,push:c")
    }

    test("bridge sends: a send from another thread reaches the page on its own") {
        let page = try BridgedPage()
        installSequenceRecorder(page)
        let bridge = page.bridge
        DispatchQueue.global(qos: .userInitiated).async { bridge.push(channel: "late", json: "1") }
        try expectEqual(sequence(page, count: 2), "push:late,~push:late")
    }

    test("bridge sends: no Bridge source evaluates into the page except the outbox flush") {
        // Callback fires (hotkey, broadcasts, urlhandler, proc streams, HTTP
        // requests) and screen updates join the outbox instead of calling
        // sdEvaluate, so they keep their place among the stack's other sends.
        let evaluate = try NSRegularExpression(pattern: #"\.(sdEvaluate|evaluateJavaScript|callAsyncJavaScript)\("#)
        var found: [String] = []
        for (name, text) in try bridgeSources() {
            let n = evaluate.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if n > 0 { found.append("\(name)×\(n)") }
        }
        try expectEqual(found, ["Bridge.swift×2"], "the gated eval(_:in:) holds the only two calls")
    }
}
