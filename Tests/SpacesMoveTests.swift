import Foundation

// Spaces.moveWindow — shape + guard contract. The happy path needs a live
// window server plus a second user space, so headless tests pin what can
// be pinned: the payload always carries both keys, zero-id guards refuse
// without touching SLS, and a move that can't verify reports ok:false.
// Live verification (window actually lands on the space) runs via the
// qa-stack flow.
func registerSpacesMoveTests() {
    test("Spaces.moveWindow refuses zero window id with the full payload shape") {
        let r = Spaces.moveWindow(windowID: 0, toSpace: 1)
        try expectEqual(r["ok"] as? Bool, false)
        try expect(r["spaces"] is [NSNumber], "spaces must be an array even on refusal")
    }

    test("Spaces.moveWindow refuses zero space id") {
        let r = Spaces.moveWindow(windowID: 4_294_000_020, toSpace: 0)
        try expectEqual(r["ok"] as? Bool, false)
        try expect(r["spaces"] is [NSNumber], "spaces must be an array even on refusal")
    }

    test("Spaces.moveWindow with a nonexistent window reports ok:false, empty spaces") {
        // Bogus window id: both SLS routes no-op server-side and the
        // verify (windowSpaces) comes back empty → refusal, not a throw.
        let r = Spaces.moveWindow(windowID: 4_294_000_021, toSpace: 999_999_999)
        try expectEqual(r["ok"] as? Bool, false)
        try expectEqual((r["spaces"] as? [NSNumber])?.count, 0,
                        "nonexistent window can't be on any space")
    }
}
