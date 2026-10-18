import Foundation

// `Spaces.windows(spaceID:)` (hs.spaces.windowsForSpace) over
// SLSCopyWindowsWithOptionsAndTags. The call is handed a one-element spaces
// array, never NULL (which crashes inside SkyLight) and never empty (which
// the window server reads as "every space"), so an id that is not a managed
// space is refused before the query. The query itself is a closure here;
// the last two tests make the real read.

private final class FakeQuery {
    var calls: [(spaces: [NSNumber], options: UInt32)] = []
    var result: CFArray?

    init(result: CFArray? = [] as CFArray) { self.result = result }

    func copy(_ spaces: CFArray, _ options: UInt32) -> CFArray? {
        calls.append(((spaces as? [NSNumber]) ?? [], options))
        return result
    }
}

func registerSpacesWindowsTests() {
    test("Spaces.windows queries exactly the one space asked for, including minimized windows") {
        let fake = FakeQuery()
        _ = Spaces.windows(spaceID: 7, includeMinimized: true, managedSpaces: [3, 7], copy: fake.copy)
        try expectEqual(fake.calls.count, 1)
        try expectEqual(fake.calls.first?.spaces.map(\.uint64Value), [7])
        try expectEqual(fake.calls.first?.options, 0x7)
    }

    test("Spaces.windows without minimized windows asks for on-screen ones only") {
        let fake = FakeQuery()
        _ = Spaces.windows(spaceID: 7, includeMinimized: false, managedSpaces: [7], copy: fake.copy)
        try expectEqual(fake.calls.first?.options, 0x2)
    }

    test("Spaces.windows refuses a space id that is not a managed space, without querying") {
        let fake = FakeQuery(result: [NSNumber(value: 1)] as CFArray)
        try expectEqual(Spaces.windows(spaceID: 9, includeMinimized: true, managedSpaces: [3, 7], copy: fake.copy), [])
        try expectEqual(Spaces.windows(spaceID: 0, includeMinimized: true, managedSpaces: [0, 7], copy: fake.copy), [])
        try expectEqual(Spaces.windows(spaceID: 7, includeMinimized: true, managedSpaces: [], copy: fake.copy), [])
        try expectEqual(fake.calls.count, 0)
    }

    test("Spaces.windows decodes the window ids and skips anything else") {
        let fake = FakeQuery(result: [NSNumber(value: 101), "x" as NSString, NSNumber(value: 4_294_967_295)] as CFArray)
        try expectEqual(Spaces.windows(spaceID: 7, includeMinimized: true, managedSpaces: [7], copy: fake.copy),
                        [101, 4_294_967_295])
    }

    test("Spaces.windows is empty when the window server answers nothing") {
        let fake = FakeQuery(result: nil)
        try expectEqual(Spaces.windows(spaceID: 7, includeMinimized: true, managedSpaces: [7], copy: fake.copy), [])
    }

    test("Spaces.windows reads the active space's windows from the window server") {
        guard let active = Spaces.all().values
            .compactMap({ (($0 as? [String: Any])?["active"] as? NSNumber)?.uint64Value }).first
        else { return }   // no managed spaces in this session
        // Returning at all is the point: the call never reaches SkyLight
        // with a NULL or empty spaces array.
        let all = Spaces.windows(spaceID: active)
        let onscreen = Spaces.windows(spaceID: active, includeMinimized: false)
        try expect(Set(onscreen).isSubset(of: Set(all)), "on-screen windows are a subset: \(onscreen) vs \(all)")
        try expectEqual(Spaces.windows(spaceID: UInt64(UInt32.max) + 12_345), [])
    }

    test("spaces.windows answers [] over the bridge for an unknown or negative id, and when denied") {
        let page = try BridgedPage()
        try expectEqual(page.answer(requestId: 41, #"{type: "spaces.windows", spaceID: 7, requestId: 41}"#), "[]")
        try page.start(permissions: ["spaces"])
        try expectEqual(page.answer(requestId: 42, #"{type: "spaces.windows", spaceID: -1, requestId: 42}"#), "[]")
        try expectEqual(page.answer(requestId: 43, #"{type: "spaces.windows", spaceID: 4294979641, requestId: 43}"#), "[]")
    }
}
