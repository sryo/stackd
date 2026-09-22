import Foundation

// Tests for `AXInstallRetryGate` in `Sources/DataSources/Windows.swift` —
// rate-limits the "a window appeared for an app we have no AX observer on,
// try installing now" retry so a burst of windows from one struggling app
// can't turn into a burst of blocking AX registrations.

func registerAXInstallRetryGateTests() {
    test("AXInstallRetryGate allows the first attempt per app") {
        var g = AXInstallRetryGate()
        try expect(g.shouldAttempt(pid: 10, now: 100))
        try expect(g.shouldAttempt(pid: 20, now: 100), "gate is per app")
    }

    test("AXInstallRetryGate holds repeat attempts inside the interval") {
        var g = AXInstallRetryGate()
        _ = g.shouldAttempt(pid: 10, now: 100)
        try expect(!g.shouldAttempt(pid: 10, now: 101))
        try expect(g.shouldAttempt(pid: 10, now: 100 + AXInstallRetryGate.minInterval))
    }
}
