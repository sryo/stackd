import Foundation

// Tests for the behavior probes `stackd doctor` runs (Sources/DoctorProbes.swift).
// Every probe is a verdict over an injected reader, so each test drives it
// with a fake and pins one of the three outcomes: works, failed, inconclusive.

/// Records what the probes asked of it. Defaults describe a healthy machine.
private final class FakeDoctorBackend: DoctorProbeBackend {
    var connectionID: Int32 = 7
    var transaction: TransactionAttempt = .committed
    private(set) var transactionAttempts = 0

    func commitEmptyTransaction() -> TransactionAttempt {
        transactionAttempts += 1
        return transaction
    }
}

func registerDoctorProbesTests() {
    // MARK: - Reporting

    test("doctor probes: each verdict prints its own marker, name and detail") {
        try expectEqual(DoctorProbes.line(ProbeResult(name: "spaces", verdict: .works("2 displays"))),
                        "✅ spaces: 2 displays")
        try expectEqual(DoctorProbes.line(ProbeResult(name: "spaces", verdict: .failed("no displays"))),
                        "❌ spaces: no displays")
        try expectEqual(DoctorProbes.line(ProbeResult(name: "spaces", verdict: .inconclusive("no data"))),
                        "⚠️  spaces: no data")
    }

    test("doctor probes: the summary counts each verdict") {
        let results = [
            ProbeResult(name: "a", verdict: .works("")),
            ProbeResult(name: "b", verdict: .works("")),
            ProbeResult(name: "c", verdict: .failed("")),
            ProbeResult(name: "d", verdict: .inconclusive("")),
            ProbeResult(name: "e", verdict: .inconclusive("")),
            ProbeResult(name: "f", verdict: .inconclusive("")),
        ]
        try expectEqual(DoctorProbes.summary(results), "doctor: 2 works, 1 failed, 3 inconclusive")
        try expectEqual(DoctorProbes.summary([]), "doctor: 0 works, 0 failed, 0 inconclusive")
    }

    test("doctor probes: the report lists each probe, then the summary") {
        let results = [
            ProbeResult(name: "a", verdict: .works("fine")),
            ProbeResult(name: "b", verdict: .inconclusive("no data")),
        ]
        try expectEqual(DoctorProbes.report(results),
                        ["✅ a: fine", "⚠️  b: no data", "doctor: 1 works, 0 failed, 1 inconclusive"])
    }

    test("doctor probes: only a failed probe counts as an issue") {
        let results = [
            ProbeResult(name: "a", verdict: .works("")),
            ProbeResult(name: "b", verdict: .failed("")),
            ProbeResult(name: "c", verdict: .inconclusive("")),
            ProbeResult(name: "d", verdict: .failed("")),
        ]
        try expectEqual(DoctorProbes.issueCount(results), 2)
        try expectEqual(DoctorProbes.issueCount([ProbeResult(name: "x", verdict: .inconclusive("no data"))]), 0)
    }

    // MARK: - WindowServer connection

    test("windowserver probe works when the connection is open and an empty transaction commits") {
        let backend = FakeDoctorBackend()
        guard case .works(let detail) = DoctorProbes.windowServerConnection(backend) else {
            throw Expectation(message: "expected works")
        }
        try expect(detail.contains("7"), "detail should name the connection id: \(detail)")
        try expectEqual(backend.transactionAttempts, 1)
    }

    test("windowserver probe fails on connection 0 without opening a transaction") {
        let backend = FakeDoctorBackend()
        backend.connectionID = 0
        guard case .failed = DoctorProbes.windowServerConnection(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expectEqual(backend.transactionAttempts, 0)
    }

    test("windowserver probe fails when the transaction symbols do not resolve") {
        let backend = FakeDoctorBackend()
        backend.transaction = .unavailable
        guard case .failed(let detail) = DoctorProbes.windowServerConnection(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expect(detail.contains("SLSTransactionCreate"), detail)
    }

    test("windowserver probe fails when SLSTransactionCreate returns nothing") {
        let backend = FakeDoctorBackend()
        backend.transaction = .createFailed
        guard case .failed(let detail) = DoctorProbes.windowServerConnection(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expect(detail.contains("SLSTransactionCreate"), detail)
    }

    // MARK: - Runner

    test("doctor probes: run reports every probe once, in order") {
        let results = DoctorProbes.run(FakeDoctorBackend())
        try expectEqual(results.map(\.name), ["windowserver"])
    }

    test("doctor probes: the live backend completes every probe without trapping") {
        let results = DoctorProbes.run(LiveDoctorBackend())
        try expectEqual(results.map(\.name), ["windowserver"])
    }
}
