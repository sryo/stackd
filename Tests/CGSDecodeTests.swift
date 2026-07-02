import Foundation

// CGSWindowEventDecoder — pure payload decode for the CGS window-event
// callback. Offsets per OmniWM's CGSEventObserver (verified against a live
// Tahoe daemon there): 806/807/1322/804/808 carry uint32 wid at offset 0;
// 1325/1326 carry uint64 spaceID at offset 0 + uint32 wid at offset 8;
// 1508 has no payload we read.
func registerCGSDecodeTests() {
    func decode(_ eventType: UInt32, _ bytes: [UInt8]) -> CGSDecodedWindowEvent {
        bytes.withUnsafeBytes { buf in
            CGSWindowEventDecoder.decode(
                eventType: eventType,
                data: buf.count > 0 ? buf.baseAddress : nil,
                length: buf.count
            )
        }
    }
    func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func u64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    test("806/807 decode wid at offset 0") {
        try expectEqual(decode(806, u32(4242)), .moved(wid: 4242))
        try expectEqual(decode(807, u32(4242)), .resized(wid: 4242))
    }

    test("804/808/1322 decode wid at offset 0") {
        try expectEqual(decode(804, u32(7)), .destroyed(wid: 7))
        try expectEqual(decode(808, u32(8)), .reordered(wid: 8))
        try expectEqual(decode(1322, u32(9)), .titleChanged(wid: 9))
    }

    test("1325/1326 decode spaceID@0 + wid@8") {
        let payload = u64(31) + u32(555)
        try expectEqual(decode(1325, payload), .spaceWindowCreated(wid: 555, spaceID: 31))
        try expectEqual(decode(1326, payload), .spaceWindowDestroyed(wid: 555, spaceID: 31))
    }

    test("1508 decodes with or without payload") {
        try expectEqual(decode(1508, []), .frontmostByMouse)
        try expectEqual(decode(1508, u32(1)), .frontmostByMouse)
    }

    test("short buffers are malformed, not crashes") {
        try expectEqual(decode(806, []), .malformed)
        try expectEqual(decode(806, [0x01, 0x02]), .malformed)
        try expectEqual(decode(1325, u64(31)), .malformed, "1325 needs 12 bytes")
    }

    test("unknown event types are ignored") {
        try expectEqual(decode(999, u32(1)), .ignored)
    }
}
