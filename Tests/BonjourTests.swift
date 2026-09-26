import Foundation
import Network

// Tests for the pure helpers in Bonjour.swift — TXT-record encode/decode
// round-tripping. The async network behavior (NWListener publish state,
// NWBrowser result enumeration) depends on what's on the LAN, so it lives
// in the live runtime, not here.

func registerBonjourTests() {
    test("encodeTXT/decodeTXT: nil and empty inputs yield an empty dict") {
        try expectEqual(Bonjour.decodeTXT(nil).count, 0)
        try expectEqual(Bonjour.decodeTXT(Bonjour.encodeTXT(nil)).count, 0)
        try expectEqual(Bonjour.decodeTXT(Bonjour.encodeTXT([:])).count, 0)
    }

    test("encodeTXT then decodeTXT round-trips multiple keys") {
        let input = ["path": "/api", "role": "primary", "ver": "1.0"]
        try expectEqual(Bonjour.decodeTXT(Bonjour.encodeTXT(input)), input)
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
