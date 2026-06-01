import Foundation
import Network

// Tests for the pure helpers in Bonjour.swift — TXT-record encode/decode
// round-tripping. The async network behavior (NWListener publish state,
// NWBrowser result enumeration) is impure and Mac-environment-coupled
// (depends on what's on the LAN), so it lives in the live runtime, not
// here. Same rationale as Spotlight.swift: test what's deterministic, not
// the macOS subsystem.
//
// Wire-up: add `registerBonjourTests()` to Tests/main.swift and append
// this file to TEST_SOURCES in tests.sh (orchestrator handles this).

func registerBonjourTests() {
    test("encodeTXT nil yields an empty record") {
        let record = Bonjour.encodeTXT(nil)
        try expectEqual(Bonjour.decodeTXT(record).count, 0)
    }

    test("encodeTXT empty dict yields an empty record") {
        let record = Bonjour.encodeTXT([:])
        try expectEqual(Bonjour.decodeTXT(record).count, 0)
    }

    test("encodeTXT then decodeTXT round-trips a single key/value") {
        let record = Bonjour.encodeTXT(["path": "/api"])
        let out = Bonjour.decodeTXT(record)
        try expectEqual(out["path"], "/api")
        try expectEqual(out.count, 1)
    }

    test("encodeTXT then decodeTXT round-trips multiple keys") {
        let input = ["path": "/api", "role": "primary", "ver": "1.0"]
        let record = Bonjour.encodeTXT(input)
        let out = Bonjour.decodeTXT(record)
        try expectEqual(out["path"], "/api")
        try expectEqual(out["role"], "primary")
        try expectEqual(out["ver"],  "1.0")
        try expectEqual(out.count, 3)
    }

    test("decodeTXT nil yields an empty dict") {
        try expectEqual(Bonjour.decodeTXT(nil).count, 0)
    }

    test("encodeTXT round-trips empty-string values") {
        // Empty TXT values are legal per RFC 6763 — used as boolean flags
        // ("foo=" means "foo is present"). The round-trip preserves the
        // key even when the value is "".
        let record = Bonjour.encodeTXT(["flag": ""])
        let out = Bonjour.decodeTXT(record)
        try expectEqual(out["flag"], "")
    }
}
