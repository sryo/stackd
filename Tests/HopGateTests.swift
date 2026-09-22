import Foundation

// Tests for `HopGate` in `Sources/DataSources/Display.swift` — the
// one-pending-hop rule that stops CVDisplayLink frames piling up as separate
// main-queue blocks when main is busy.

func registerHopGateTests() {
    test("HopGate.arm succeeds once, then refuses until disarmed") {
        var gate = HopGate()
        try expect(gate.arm())
        try expect(!gate.arm())
        try expect(!gate.arm())
    }

    test("HopGate.disarm re-opens the gate for the next frame") {
        var gate = HopGate()
        _ = gate.arm()
        gate.disarm()
        try expect(gate.arm())
    }
}
