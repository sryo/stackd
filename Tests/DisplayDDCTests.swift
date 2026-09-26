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

    test("encodeBrightnessSet keeps 0...100 and clamps outside it") {
        // Negative input must not wrap into a high byte (≈ max brightness);
        // values above 100 clamp to the v1 0..100 contract. MSB stays 0
        // across the whole range. The checksum must track the clamped value.
        let cases: [(input: Int, lsb: UInt8)] = [(0, 0x00), (100, 0x64), (-10, 0x00), (250, 0x64)]
        for c in cases {
            let p = DisplayDDC.encodeBrightnessSet(percent: c.input)
            try expectEqual(p[3], 0x00, "MSB for \(c.input)")
            try expectEqual(p[4], c.lsb, "LSB for \(c.input)")
            try expectEqual(p[5], DisplayDDC.checksum(destinationAddress: 0x6E, bytes: [0x51] + Array(p[0..<5])),
                            "checksum for \(c.input)")
        }
    }

    test("encodeBrightnessRead packs length, get-opcode, vcp, chk") {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC
        try expectEqual(DisplayDDC.encodeBrightnessRead(), [0x82, 0x01, 0x10, 0xAC])
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
        // The MSB counts: current=0x012C (300) on a monitor with a wide range.
        var wide = reply
        wide[8] = 0x01; wide[9] = 0x2C
        try expectEqual(DisplayDDC.parseBrightnessReply(wide), 300)
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
