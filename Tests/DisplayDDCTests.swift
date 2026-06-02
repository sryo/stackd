import Foundation

// Tests for the pure VCP/DDC packet-encoding helpers that drive
// `sd.display.setBrightness` on external monitors. The IOAVService I/O path
// itself is impure (it talks to a private framework + live I²C bus) so it
// can't be unit-tested here — but the wire format is the bug surface. A
// single off-by-one in the checksum or a swapped MSB/LSB silently breaks
// every external-display brightness call across every monitor vendor.
//
// Format reference: VESA MCCS over DDC/CI, as consumed by MonitorControl's
// Arm64DDC.swift. Clean-room reimplementation from the spec — see
// Sources/DataSources/DisplayDDC.swift for the runtime side.

func registerDisplayDDCTests() {
    // The DDC/CI XOR checksum mixes the destination 8-bit I²C address
    // (0x37 << 1 = 0x6E) into the running XOR of the payload bytes. Any
    // monitor that gets the wrong checksum drops the packet silently —
    // so this gets locked down first.
    test("checksum is destination address XORed with all payload bytes") {
        // Hand-computed: 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32
        // 0x6E ^ 0x51 = 0x3F
        // 0x3F ^ 0x84 = 0xBB
        // 0xBB ^ 0x03 = 0xB8
        // 0xB8 ^ 0x10 = 0xA8
        // 0xA8 ^ 0x00 = 0xA8
        // 0xA8 ^ 0x32 = 0x9A
        let chk = DisplayDDC.checksum(
            destinationAddress: 0x6E,
            bytes: [0x51, 0x84, 0x03, 0x10, 0x00, 0x32]
        )
        try expectEqual(chk, 0x9A)
    }

    test("checksum of empty payload equals the destination address itself") {
        // Edge case — XOR identity. Not a real packet but the math has to
        // hold so the helper is composable.
        try expectEqual(DisplayDDC.checksum(destinationAddress: 0x6E, bytes: []), 0x6E)
    }

    // encodeBrightnessSet returns the full 6-byte payload that
    // IOAVServiceWriteI2C transmits after the (0x37, 0x51) addr/subaddr
    // pair. Layout: [length=0x84, opcode=0x03, vcp=0x10, hi, lo, chk].
    test("encodeBrightnessSet(50) packs length, opcode, vcp, hi, lo, chk") {
        let p = DisplayDDC.encodeBrightnessSet(percent: 50)
        try expectEqual(p.count, 6)
        try expectEqual(p[0], 0x84)         // 0x80 | 4 data bytes
        try expectEqual(p[1], 0x03)         // set VCP feature
        try expectEqual(p[2], 0x10)         // brightness VCP code
        try expectEqual(p[3], 0x00)         // MSB — always 0 for 0..100 range
        try expectEqual(p[4], 0x32)         // LSB — 50 decimal
        // Recomputed: 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
        try expectEqual(p[5], 0x9A)
    }

    test("encodeBrightnessSet clamps percent below 0 to 0") {
        // Negative input shouldn't underflow into a wrap-around byte (which
        // would set the monitor to ~maximum). Clamp at the boundary.
        let p = DisplayDDC.encodeBrightnessSet(percent: -10)
        try expectEqual(p[4], 0x00)
    }

    test("encodeBrightnessSet clamps percent above 100 to 100") {
        // Some monitors interpret values > their declared max as 0 or
        // saturate randomly. Clamp at 100 to match the v1 0..100 contract.
        let p = DisplayDDC.encodeBrightnessSet(percent: 250)
        try expectEqual(p[4], 0x64)         // 100 decimal
    }

    test("encodeBrightnessSet(100) emits MSB=0 LSB=0x64") {
        // Boundary at the high end. MSB stays 0 — only matters for monitors
        // that report a max value > 255 via the capabilities string, out of
        // scope for v1.
        let p = DisplayDDC.encodeBrightnessSet(percent: 100)
        try expectEqual(p[3], 0x00)
        try expectEqual(p[4], 0x64)
    }

    test("encodeBrightnessSet(0) emits MSB=0 LSB=0") {
        // Zero is a real value (full dim) — must not be confused with the
        // clamp path.
        let p = DisplayDDC.encodeBrightnessSet(percent: 0)
        try expectEqual(p[3], 0x00)
        try expectEqual(p[4], 0x00)
    }

    // The brightness-read reply is an 11-byte block: source addr, length,
    // op (0x02 = VCP feature reply), result code, vcp code, type, then
    // max-value (hi/lo) and current-value (hi/lo), then checksum. We only
    // care about the current-value 16-bit pair at offsets [8..9].
    test("parseBrightnessReply extracts current value from offsets 8..9") {
        // Fake reply with max=0x0064 (100) and current=0x002A (42).
        let reply: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, 0x10, 0x00,
            0x00, 0x64,   // max value MSB/LSB
            0x00, 0x2A,   // current value MSB/LSB — what we want
            0x00          // checksum (unverified in v1)
        ]
        try expectEqual(DisplayDDC.parseBrightnessReply(reply), 42)
    }

    test("parseBrightnessReply returns nil for a too-short buffer") {
        // DDC reads can short-return when the monitor doesn't actually
        // implement the read side of VCP (very common). Surface as nil so
        // the JS layer sees a clean null, not a crash.
        try expect(DisplayDDC.parseBrightnessReply([0x6E, 0x88]) == nil)
    }

    test("parseBrightnessReply rejects a reply with the wrong opcode") {
        // 0x02 is the VCP feature-reply opcode. Anything else means the
        // monitor sent us garbage / a different reply we shouldn't decode.
        let reply: [UInt8] = [
            0x6E, 0x88, 0xFF, 0x00, 0x10, 0x00,
            0x00, 0x64, 0x00, 0x2A, 0x00
        ]
        try expect(DisplayDDC.parseBrightnessReply(reply) == nil)
    }

    test("parseBrightnessReply rejects a non-zero result-code byte") {
        // The byte at offset 3 is the result code; non-zero means the
        // monitor returned an error for this VCP code (e.g. unsupported).
        let reply: [UInt8] = [
            0x6E, 0x88, 0x02, 0x01, 0x10, 0x00,
            0x00, 0x64, 0x00, 0x2A, 0x00
        ]
        try expect(DisplayDDC.parseBrightnessReply(reply) == nil)
    }
}
