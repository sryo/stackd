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

    var ownPID: pid_t = 100
    var ownName = "stackd"
    var windows: [ListedWindow] = []
    /// Replaces the default read (the window's listed bounds); called with the
    /// window id and the 1-based index of the read.
    var serverBoundsOverride: ((CGWindowID, Int) -> CGRect?)?
    private(set) var serverReads = 0
    private(set) var listings = 0

    func onScreenWindows() -> [ListedWindow] {
        listings += 1
        return windows
    }

    func serverBounds(of id: CGWindowID) -> CGRect? {
        serverReads += 1
        if let override = serverBoundsOverride { return override(id, serverReads) }
        return windows.first { $0.id == id }?.bounds
    }

    var spaceCounts: [Int] = [2]

    func spaceCountsByDisplay() -> [Int] { spaceCounts }
}

private func listed(_ id: CGWindowID, pid: pid_t = 500, owner: String = "Safari", layer: Int = 0,
                    _ bounds: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600)) -> ListedWindow {
    ListedWindow(id: id, ownerPID: pid, ownerName: owner, layer: layer, bounds: bounds)
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

    // MARK: - Window bounds agreement

    test("bounds probe is inconclusive when no window is on screen") {
        guard case .inconclusive = DoctorProbes.windowBounds(FakeDoctorBackend()) else {
            throw Expectation(message: "expected inconclusive")
        }
    }

    test("bounds probe only samples layer-0 windows that stackd does not own") {
        let backend = FakeDoctorBackend()
        backend.windows = [
            listed(1, pid: 100, owner: "Terminal"),
            listed(2, pid: 900, owner: "stackd"),
            listed(3, layer: 25),
            listed(4, CGRect(x: 0, y: 0, width: 0, height: 40)),
        ]
        guard case .inconclusive = DoctorProbes.windowBounds(backend) else {
            throw Expectation(message: "expected inconclusive")
        }
        try expectEqual(backend.serverReads, 0)
    }

    test("bounds probe works when the window server agrees with CGWindowList") {
        let backend = FakeDoctorBackend()
        backend.windows = [listed(1), listed(2)]
        guard case .works(let detail) = DoctorProbes.windowBounds(backend) else {
            throw Expectation(message: "expected works")
        }
        try expect(detail.contains("2"), "detail should count the windows: \(detail)")
    }

    test("bounds probe reads at most three windows, front to back") {
        let backend = FakeDoctorBackend()
        backend.windows = (1...5).map { listed(CGWindowID($0)) }
        var read: [CGWindowID] = []
        backend.serverBoundsOverride = { id, _ in
            read.append(id)
            return CGRect(x: 10, y: 20, width: 800, height: 600)
        }
        _ = DoctorProbes.windowBounds(backend)
        try expectEqual(read, [1, 2, 3])
    }

    test("bounds probe tolerates a one point difference and no more") {
        let base = CGRect(x: 10, y: 20, width: 800, height: 600)
        try expect(DoctorProbes.boundsAgree(base, base.offsetBy(dx: 1, dy: -1)))
        try expect(DoctorProbes.boundsAgree(base, CGRect(x: 10, y: 20, width: 801, height: 599)))
        try expect(!DoctorProbes.boundsAgree(base, base.offsetBy(dx: 1.01, dy: 0)))
        try expect(!DoctorProbes.boundsAgree(base, CGRect(x: 10, y: 20, width: 800, height: 602)))
    }

    test("bounds probe fails and names the window when the bounds differ") {
        let backend = FakeDoctorBackend()
        backend.windows = [listed(1), listed(42, owner: "Notes")]
        backend.serverBoundsOverride = { id, _ in
            id == 42 ? CGRect(x: 10, y: 20, width: 900, height: 600) : CGRect(x: 10, y: 20, width: 800, height: 600)
        }
        guard case .failed(let detail) = DoctorProbes.windowBounds(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expect(detail.contains("42") && detail.contains("Notes"), detail)
        try expect(detail.contains("900"), "detail should show the server's bounds: \(detail)")
    }

    test("bounds probe fails when the window server will not read a listed window") {
        let backend = FakeDoctorBackend()
        backend.windows = [listed(1)]
        backend.serverBoundsOverride = { _, _ in nil }
        guard case .failed(let detail) = DoctorProbes.windowBounds(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expect(detail.contains("SLSGetWindowBounds"), detail)
    }

    test("bounds probe forgives a window that moved between the two reads") {
        let backend = FakeDoctorBackend()
        backend.windows = [listed(1)]
        backend.serverBoundsOverride = { _, read in
            read == 1 ? CGRect(x: 300, y: 20, width: 800, height: 600) : CGRect(x: 10, y: 20, width: 800, height: 600)
        }
        guard case .works = DoctorProbes.windowBounds(backend) else {
            throw Expectation(message: "expected works")
        }
        try expectEqual(backend.listings, 2)
    }

    test("bounds probe keeps the failure when a second look still disagrees") {
        let backend = FakeDoctorBackend()
        backend.windows = [listed(1)]
        backend.serverBoundsOverride = { _, _ in CGRect(x: 300, y: 20, width: 800, height: 600) }
        guard case .failed = DoctorProbes.windowBounds(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expectEqual(backend.listings, 2)
    }

    // MARK: - Spaces

    test("spaces probe works when a display lists spaces") {
        let backend = FakeDoctorBackend()
        backend.spaceCounts = [3, 2]
        guard case .works(let detail) = DoctorProbes.spaces(backend) else {
            throw Expectation(message: "expected works")
        }
        try expect(detail.contains("2 display") && detail.contains("5 space"), detail)
    }

    test("spaces probe works as long as one display has a space") {
        let backend = FakeDoctorBackend()
        backend.spaceCounts = [0, 1]
        guard case .works = DoctorProbes.spaces(backend) else {
            throw Expectation(message: "expected works")
        }
    }

    test("spaces probe fails when SLSCopyManagedDisplaySpaces lists no display") {
        let backend = FakeDoctorBackend()
        backend.spaceCounts = []
        guard case .failed(let detail) = DoctorProbes.spaces(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expect(detail.contains("SLSCopyManagedDisplaySpaces"), detail)
    }

    test("spaces probe fails when displays are listed but none has a space") {
        let backend = FakeDoctorBackend()
        backend.spaceCounts = [0, 0]
        guard case .failed(let detail) = DoctorProbes.spaces(backend) else {
            throw Expectation(message: "expected failed")
        }
        try expect(detail.contains("2 display"), detail)
    }

    // MARK: - Runner

    test("doctor probes: run reports every probe once, in order") {
        let results = DoctorProbes.run(FakeDoctorBackend())
        try expectEqual(results.map(\.name), ["windowserver", "window-bounds", "spaces"])
    }

    test("doctor probes: the live backend completes every probe without trapping") {
        let results = DoctorProbes.run(LiveDoctorBackend())
        try expectEqual(results.map(\.name), ["windowserver", "window-bounds", "spaces"])
    }
}
