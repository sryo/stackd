import Foundation

// Tests for `PerWindowCoverage` in `Sources/DataSources/Windows.swift` —
// which listed windows the safety poll re-attaches per-window AX observers
// to. A window whose observers never attached (subrole ladder ran dry, AX
// didn't vend it yet when CGS announced it) otherwise gets no minimize /
// deminimize / moved / resized events for its whole life.

func registerPerWindowCoverageTests() {
    func row(_ id: Int, pid: Int = 10, standard: Bool = true, addressable: Bool = true) -> [String: Any] {
        ["id": id, "pid": pid, "isStandard": standard, "addressable": addressable]
    }

    test("PerWindowCoverage picks standard addressable windows without observers") {
        let got = PerWindowCoverage.uncovered(rows: [row(1), row(2, pid: 20)], covered: { $0 == 1 })
        try expect(got.map { $0.id } == [2])
        try expect(got.map { $0.pid } == [20])
    }

    test("PerWindowCoverage skips windows AX can't address") {
        let got = PerWindowCoverage.uncovered(rows: [row(1, addressable: false)], covered: { _ in false })
        try expect(got.isEmpty)
    }

    test("PerWindowCoverage skips non-standard windows") {
        let got = PerWindowCoverage.uncovered(rows: [row(1, standard: false)], covered: { _ in false })
        try expect(got.isEmpty)
    }

    test("PerWindowCoverage skips rows missing id or pid") {
        let got = PerWindowCoverage.uncovered(
            rows: [["pid": 10, "isStandard": true, "addressable": true],
                   ["id": 3, "isStandard": true, "addressable": true]],
            covered: { _ in false })
        try expect(got.isEmpty)
    }

    test("PerWindowCoverage gate allows the first attempt per window") {
        var gate = PerWindowCoverage.Gate()
        try expect(gate.shouldAttempt(id: 1, now: 100))
        try expect(gate.shouldAttempt(id: 2, now: 100))
    }

    test("PerWindowCoverage gate holds a window back until the interval passes") {
        var gate = PerWindowCoverage.Gate()
        _ = gate.shouldAttempt(id: 1, now: 100)
        try expect(!gate.shouldAttempt(id: 1, now: 100 + PerWindowCoverage.retryInterval - 1))
        try expect(gate.shouldAttempt(id: 1, now: 100 + PerWindowCoverage.retryInterval))
    }

    test("PerWindowCoverage gate forgets windows that left the list") {
        var gate = PerWindowCoverage.Gate()
        _ = gate.shouldAttempt(id: 1, now: 100)
        gate.retain(ids: [])
        try expect(gate.shouldAttempt(id: 1, now: 101))
    }
}
