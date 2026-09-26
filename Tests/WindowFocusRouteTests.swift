import Foundation

// sd.windows.byId.focus (WindowsByID.focus in Sources/DataSources/Windows.swift):
// the pure halves of the SkyLight focus path. KeyWindowEventRecord builds
// the synthetic event records SLPSPostEventRecordTo delivers to make a
// window key; WindowFocusRoute picks the SkyLight or the NSRunningApplication
// path and when the AX raise runs.

func registerWindowFocusRouteTests() {
    func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    test("KeyWindowEventRecord: press then release, in that order") {
        let records = KeyWindowEventRecord.pressAndRelease(windowID: 1)
        try expectEqual(records.count, 2)
        try expectEqual(records[0][0x08], 0x01)
        try expectEqual(records[1][0x08], 0x02)
    }

    test("KeyWindowEventRecord: 0xf8-byte record declaring its length") {
        for r in KeyWindowEventRecord.pressAndRelease(windowID: 1) {
            try expectEqual(r.count, 0xF8)
            try expectEqual(r[0x04], 0xF8)
        }
    }

    test("KeyWindowEventRecord: key-window flag and little-endian window id") {
        for r in KeyWindowEventRecord.pressAndRelease(windowID: 0x1234_5678) {
            try expectEqual(r[0x3A], 0x10)
            try expectEqual(u32(r, 0x3C), 0x1234_5678)
        }
    }

    test("KeyWindowEventRecord: location field is all ones, everything else zero") {
        for r in KeyWindowEventRecord.pressAndRelease(windowID: 7) {
            for i in 0x20..<0x30 { try expectEqual(r[i], 0xFF, "byte \(i)") }
            let set = Set([0x04, 0x08, 0x3A, 0x3C, 0x3D, 0x3E, 0x3F]).union(0x20..<0x30)
            for i in 0..<r.count where !set.contains(i) {
                try expectEqual(r[i], 0, "byte \(i)")
            }
        }
    }

    test("WindowFocusRoute: missing SkyLight symbols fall back to app activation") {
        try expectEqual(WindowFocusRoute.decide(skyLightAvailable: false, targetPid: 10, frontmostPid: 20),
                        .activateApp)
        try expectEqual(WindowFocusRoute.decide(skyLightAvailable: false, targetPid: 10, frontmostPid: 10),
                        .activateApp)
    }

    test("WindowFocusRoute: a window of the frontmost app raises immediately") {
        try expectEqual(WindowFocusRoute.decide(skyLightAvailable: true, targetPid: 10, frontmostPid: 10),
                        .skyLight(raiseAfter: 0))
    }

    test("WindowFocusRoute: another app's window raises after its activation settles") {
        try expectEqual(WindowFocusRoute.decide(skyLightAvailable: true, targetPid: 10, frontmostPid: 20),
                        .skyLight(raiseAfter: WindowFocusRoute.crossAppRaiseDelay))
        try expectEqual(WindowFocusRoute.decide(skyLightAvailable: true, targetPid: 10, frontmostPid: nil),
                        .skyLight(raiseAfter: WindowFocusRoute.crossAppRaiseDelay))
    }
}
