import Foundation

// Tests for HTTPServer.swift. The interesting parsers (tryParse,
// splitQuery, isLoopback, send) are all `private` and we can't widen
// visibility per the test constraints — they're exercised end-to-end by
// the live runtime, not here. What IS reachable from outside the type:
//
//   - HTTPServer.reasonPhrase(_:) — static, pure, the only HTTP-text
//     mapping the daemon owns. Drift in this table changes wire bytes
//     for every stack that returns a non-200 status, so we pin the
//     documented codes + the default-to-OK fallback for unknowns.
//   - HTTPRequest / HTTPResponse — value-type defaults. Stacks read the
//     fields directly from the JS bridge; the defaults are part of the
//     authoring contract (status: 200, empty headers/body, bodyBytes
//     nil so the string body path is the default).
//   - init/start/stop lifecycle — one witness test, port 0 so the
//     kernel picks an ephemeral port and we don't collide with the live
//     daemon. Just proves the listener constructs + cancels cleanly;
//     real request/response flow is covered by the runtime stacks.
//
// Gaps documented (not tested here):
//   - HTTP/1.1 request parsing (method, path, query, headers, body)
//   - Response framing (status line, Content-Length, Connection: close)
//   - Loopback gating when bindHost != "0.0.0.0"
//   - bodyBytes precedence over body
//   These are all behind `private` helpers and only observable via a
//   real TCP round-trip, which belongs in an integration test, not
//   this unit-test surface.
//
// Wire-up: orchestrator adds `registerHTTPServerTests()` to
// Tests/main.swift and appends this file to TEST_SOURCES in tests.sh.

func registerHTTPServerTests() {
    // ── reasonPhrase: the documented status-code table ───────────────────
    test("reasonPhrase maps 200 to OK") {
        try expectEqual(HTTPServer.reasonPhrase(200), "OK")
    }

    test("reasonPhrase maps the documented status codes") {
        // Pin every code the switch enumerates. Drift here changes the
        // status line for every stack that returns the corresponding code.
        try expectEqual(HTTPServer.reasonPhrase(204), "No Content")
        try expectEqual(HTTPServer.reasonPhrase(301), "Moved Permanently")
        try expectEqual(HTTPServer.reasonPhrase(302), "Found")
        try expectEqual(HTTPServer.reasonPhrase(400), "Bad Request")
        try expectEqual(HTTPServer.reasonPhrase(401), "Unauthorized")
        try expectEqual(HTTPServer.reasonPhrase(403), "Forbidden")
        try expectEqual(HTTPServer.reasonPhrase(404), "Not Found")
        try expectEqual(HTTPServer.reasonPhrase(500), "Internal Server Error")
    }

    test("reasonPhrase falls back to OK for unknown codes") {
        // The default branch is intentional — unknown codes still get a
        // valid HTTP/1.1 status line rather than an empty reason phrase.
        try expectEqual(HTTPServer.reasonPhrase(418), "OK")
        try expectEqual(HTTPServer.reasonPhrase(999), "OK")
        try expectEqual(HTTPServer.reasonPhrase(0),   "OK")
    }

    // ── HTTPResponse defaults: the JS-bridge contract ────────────────────
    test("HTTPResponse default-initializes to a 200 with empty body") {
        // Stacks that build a response incrementally (response.status =
        // 404, response.body = "...") rely on these defaults. The
        // bodyBytes default of nil is what makes the string-body path the
        // common case — base64 payloads are the explicit opt-in.
        let r = HTTPResponse()
        try expectEqual(r.status, 200)
        try expectEqual(r.headers.count, 0)
        try expectEqual(r.body, "")
        try expect(r.bodyBytes == nil, "bodyBytes default should be nil")
    }

    test("HTTPResponse field assignment is direct") {
        // Witness that the struct is a plain value type — no
        // willSet/didSet, no computed properties. Stacks mutate fields
        // directly from the bridge callback.
        var r = HTTPResponse()
        r.status = 404
        r.headers["Content-Type"] = "text/plain"
        r.body = "not found"
        try expectEqual(r.status, 404)
        try expectEqual(r.headers["Content-Type"], "text/plain")
        try expectEqual(r.body, "not found")
    }

    // ── Lifecycle witness ────────────────────────────────────────────────
    test("HTTPServer init+start+stop on port 0 does not throw") {
        // Port 0 asks the kernel for an ephemeral port — no collision
        // with the live daemon (which sits on whatever the user's stacks
        // configured). This is a lifecycle smoke test; we're not driving
        // a request through. The onRequest callback is never invoked
        // because no connection arrives during the test window.
        var threw = false
        do {
            let server = try HTTPServer(
                port: 0,
                bindHost: "127.0.0.1",
                bonjourType: nil,
                bonjourName: nil,
                onRequest: { _, complete in complete(HTTPResponse()) }
            )
            server.start()
            server.stop()
        } catch {
            threw = true
        }
        try expect(!threw, "HTTPServer lifecycle on port 0 should not throw")
    }
}
