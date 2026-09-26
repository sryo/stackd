import Foundation

// Tests for HTTPServer.swift. The request parser, query splitter, loopback
// gate and response framing are private and only observable through a real
// TCP round-trip — and the assigned port of a port-0 listener isn't exposed,
// so no round-trip is attempted here. Starting a listener in the test
// process would also bind every interface (loopback gating is
// per-connection), which can raise the application-firewall prompt.
//
// What IS reachable from outside the type:
//   - HTTPServer.reasonPhrase(_:) — the only HTTP-text mapping the daemon
//     owns. Drift in this table changes wire bytes for every stack that
//     returns a non-200 status.
//   - HTTPResponse defaults — part of the authoring contract (status 200,
//     empty headers/body, bodyBytes nil so the string body is the default).

func registerHTTPServerTests() {
    test("reasonPhrase maps the documented status codes") {
        try expectEqual(HTTPServer.reasonPhrase(200), "OK")
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
        // Unknown codes still get a non-empty reason phrase so the status
        // line stays well-formed.
        try expectEqual(HTTPServer.reasonPhrase(418), "OK")
        try expectEqual(HTTPServer.reasonPhrase(999), "OK")
        try expectEqual(HTTPServer.reasonPhrase(0),   "OK")
    }

    test("HTTPResponse default-initializes to a 200 with empty body") {
        // Stacks that build a response incrementally rely on these
        // defaults; bodyBytes nil keeps the string-body path the default
        // and base64 payloads the explicit opt-in.
        let r = HTTPResponse()
        try expectEqual(r.status, 200)
        try expectEqual(r.headers.count, 0)
        try expectEqual(r.body, "")
        try expect(r.bodyBytes == nil, "bodyBytes default should be nil")
    }
}
