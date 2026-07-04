import Foundation

// Spaces.entries — the pure mapping from the SLSCopyManagedDisplaySpaces
// snapshot to the per-UUID sd.spaces.all payload. Impure inputs (CGS copy,
// NSScreen maps, SPI reads) are injected as values/closures so the mapping
// is pinnable headless. Output shape is a stack-facing contract:
//   { uuid: { spaces: [id], active: id|null, isFullscreen: bool, displayID?: int } }

private func display(_ ident: String, spaces: [UInt64], current: UInt64?) -> [String: Any] {
    var d: [String: Any] = [
        "Display Identifier": ident,
        "Spaces": spaces.map { ["ManagedSpaceID": NSNumber(value: $0)] }
    ]
    if let c = current {
        d["Current Space"] = ["ManagedSpaceID": NSNumber(value: c)]
    }
    return d
}

private func entry(_ out: [String: Any], _ key: String) -> [String: Any]? {
    out[key] as? [String: Any]
}

func registerSpacesTests() {
    test("Spaces.entries remaps the literal Main identifier to the main screen UUID") {
        let out = Spaces.entries(
            displays: [display("Main", spaces: [1, 2], current: 1)],
            mainScreenUUID: "UUID-MAIN",
            displayIDByUUID: ["UUID-MAIN": 7],
            currentSpace: { _ in nil },
            spaceType: { _ in nil })
        try expect(out["Main"] == nil, "raw Main key must not leak into the output")
        let e = entry(out, "UUID-MAIN")
        try expect(e != nil, "entry must be keyed by the remapped UUID")
        try expectEqual(e?["displayID"] as? Int, 7, "displayID joins via the remapped key")
    }

    test("Spaces.entries queries currentSpace with the raw identifier, before the Main remap") {
        var seen: [String] = []
        _ = Spaces.entries(
            displays: [display("Main", spaces: [1], current: 1)],
            mainScreenUUID: "UUID-MAIN",
            displayIDByUUID: [:],
            currentSpace: { seen.append($0); return nil },
            spaceType: { _ in nil })
        try expectEqual(seen, ["Main"])
    }

    test("Spaces.entries extracts space ids in Spaces-array order") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [5, 3, 9], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in nil },
            spaceType: { _ in nil })
        let ids = (entry(out, "UUID-A")?["spaces"] as? [NSNumber])?.map { $0.uint64Value }
        try expectEqual(ids, [5, 3, 9])
    }

    test("Spaces.entries prefers the currentSpace closure over the embedded Current Space") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3, 42], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in 42 },
            spaceType: { _ in nil })
        try expectEqual(entry(out, "UUID-A")?["active"] as? NSNumber, NSNumber(value: 42 as UInt64))
    }

    test("Spaces.entries falls back to the embedded Current Space when the closure returns nil") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in nil },
            spaceType: { _ in nil })
        try expectEqual(entry(out, "UUID-A")?["active"] as? NSNumber, NSNumber(value: 3 as UInt64))
    }

    test("Spaces.entries falls back to the embedded Current Space when the closure returns 0") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in 0 },
            spaceType: { _ in nil })
        try expectEqual(entry(out, "UUID-A")?["active"] as? NSNumber, NSNumber(value: 3 as UInt64))
    }

    test("Spaces.entries reports active as NSNull when neither source has a value") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3], current: nil)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in nil },
            spaceType: { _ in nil })
        try expect(entry(out, "UUID-A")?["active"] is NSNull, "active must be NSNull, not absent")
    }

    test("Spaces.entries marks isFullscreen when the active space type is 4") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3, 42], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in 42 },
            spaceType: { sid in sid == 42 ? 4 : 0 })
        try expectEqual(entry(out, "UUID-A")?["isFullscreen"] as? Bool, true,
                        "type check must run against the closure-resolved active, not the embedded one")
    }

    test("Spaces.entries keeps isFullscreen false for user space type 0") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in nil },
            spaceType: { _ in 0 })
        try expectEqual(entry(out, "UUID-A")?["isFullscreen"] as? Bool, false)
    }

    test("Spaces.entries keeps isFullscreen false when spaceType is unavailable") {
        let out = Spaces.entries(
            displays: [display("UUID-A", spaces: [3], current: 3)],
            mainScreenUUID: nil,
            displayIDByUUID: [:],
            currentSpace: { _ in nil },
            spaceType: { _ in nil })
        try expectEqual(entry(out, "UUID-A")?["isFullscreen"] as? Bool, false)
    }
}
