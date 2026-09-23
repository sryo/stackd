import Foundation

// Tests for `PerWindowInstallDecision` in `Sources/DataSources/Windows.swift`
// — whether a window re-found by the safety poll or a CGS create needs its
// per-window AX observers (re)attached. Observers stored for a dead element
// (e.g. after sleep) would otherwise block re-installation forever.

func registerPerWindowInstallDecisionTests() {
    let same: (String, String) -> Bool = { $0 == $1 }

    test("PerWindowInstallDecision installs when nothing is stored") {
        try expect(PerWindowInstallDecision.decide(existing: nil, fresh: "el", same: same) == .install)
    }

    test("PerWindowInstallDecision replaces observers stored for a different element") {
        try expect(PerWindowInstallDecision.decide(existing: "old", fresh: "new", same: same) == .replace)
    }

    test("PerWindowInstallDecision keeps observers for the same element") {
        try expect(PerWindowInstallDecision.decide(existing: "el", fresh: "el", same: same) == .keep)
    }

    test("PerWindowInstallDecision does nothing when AX can't resolve the window") {
        try expect(PerWindowInstallDecision.decide(existing: "el", fresh: nil, same: same) == .keep)
        try expect(PerWindowInstallDecision.decide(existing: nil as String?, fresh: nil, same: same) == .keep)
    }
}
