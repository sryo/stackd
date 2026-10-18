import Foundation

// CGSWindowEventDecoder — pure payload decode for the CGS window-event
// callback. Offsets per OmniWM's CGSEventObserver (verified against a live
// Tahoe daemon there): 806/807/1322/804/808 carry uint32 wid at offset 0;
// 1325/1326 carry uint64 spaceID at offset 0 + uint32 wid at offset 8;
// 1508 carries the new frontmost pid (int32) at offset 0.
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

    test("1508 decodes as frontmostByMouse whatever the payload") {
        // macOS 27 posts it with an empty payload: no pid to read.
        try expectEqual(decode(1508, []), .frontmostByMouse)
        try expectEqual(decode(1508, u32(4321)), .frontmostByMouse)
    }

    test("1327 decodes as animationBegan whatever the payload (a counter, not a wid)") {
        try expectEqual(decode(1327, u32(12345)), .animationBegan)
        try expectEqual(decode(1327, []), .animationBegan)
    }

    test("short buffers are malformed, not crashes") {
        try expectEqual(decode(806, []), .malformed)
        try expectEqual(decode(806, [0x01, 0x02]), .malformed)
        try expectEqual(decode(1325, u64(31)), .malformed, "1325 needs 12 bytes")
    }

    test("probe codes decode their leading payload words") {
        for code: UInt32 in [802, 803, 809, 811, 1400, 1411, 1412, 1413] {
            try expectEqual(decode(code, u32(4242) + u32(7)), .probe(code: code, words: [4242, 7]))
        }
    }

    test("probe decode caps the words and drops a trailing partial word") {
        let six: [UInt8] = (1...6).flatMap { u32(UInt32($0)) } + [0xff]
        try expectEqual(decode(1411, six), .probe(code: 1411, words: [1, 2, 3, 4]))
        try expectEqual(decode(1412, [0x01, 0x02]), .probe(code: 1412, words: []))
        try expectEqual(decode(1413, []), .probe(code: 1413, words: []))
    }

    test("probe events never reach the intake") {
        try expectEqual(IntakeEvent.window(.probe(code: 1411, words: [1])).key, nil)
    }

    test("probe log line names the code and prints words in hex") {
        try expectEqual(CGSProbe.describe(code: 1411, words: [0x1a2b, 0], length: 8),
                        "1411 windowDragDidStart len=8 words=[0x00001a2b 0x00000000]")
    }

    test("unknown event types are ignored") {
        try expectEqual(decode(999, u32(1)), .ignored)
    }

    test("fast-create gate announces only positively-standard subroles") {
        // Layer 0 alone admits app helper windows (Arc's tab-creation
        // hint). nil = AX not readable yet — must defer to the AX create
        // path, not announce optimistically.
        func gate(_ subrole: String?) -> Bool {
            WindowEvents.fastCreateAnnounceable(installed: nil, read: { subrole })
        }
        try expect(gate("AXStandardWindow"))
        try expect(!gate(nil), "unreadable must defer")
        try expect(!gate("AXDialog"))
        try expect(!gate("AXSystemDialog"))
        try expect(!gate("AXUnknown"))
    }

    test("fast-create gate decides on the subrole the per-window install just read, without reading it again") {
        var reads = 0
        let read: () -> String? = { reads += 1; return "AXStandardWindow" }
        try expect(WindowEvents.fastCreateAnnounceable(installed: .standard, read: read))
        try expect(!WindowEvents.fastCreateAnnounceable(installed: .nonStandard, read: read))
        try expect(!WindowEvents.fastCreateAnnounceable(installed: .unknown, read: read),
                   "an unreadable install read defers to the AX create path")
        try expectEqual(reads, 0, "the install's reading is the gate's reading")
        try expect(WindowEvents.fastCreateAnnounceable(installed: nil, read: read),
                   "with no install read, the gate reads once itself")
        try expectEqual(reads, 1)
    }
}
