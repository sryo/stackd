import CoreGraphics
import Foundation

// MARK: ============================================================
// MARK: Doctor behavior probes
// MARK: ============================================================

// `stackd doctor` first checks that the private SkyLight symbols resolve. A
// symbol can resolve and still misbehave: bound with the wrong signature, or
// refused by a newer macOS. These probes call the real read paths and judge
// what comes back. Each is read-only: it creates no window, posts no event
// and moves nothing.
//
// A probe is a pure verdict over an injected reader, so unit tests drive it
// with a fake. The verdict is tri-state: `inconclusive` means the probe had
// nothing to judge (Accessibility not granted, no window to compare), which
// is neither a pass nor a regression and never changes doctor's exit status.

enum ProbeVerdict: Equatable {
    case works(String)
    case failed(String)
    case inconclusive(String)
}

struct ProbeResult: Equatable {
    let name: String
    let verdict: ProbeVerdict
}

/// What an empty window-server transaction did.
enum TransactionAttempt: Equatable {
    /// SLSTransactionCreate or SLSTransactionCommit does not resolve.
    case unavailable
    case createFailed
    /// Created and committed. The commit returns nothing, so reaching this
    /// point without a fault is the whole signal.
    case committed
}

/// The WindowServer connection stackd's window code addresses.
protocol WindowServerConnectionReading {
    /// 0 when there is no connection.
    var connectionID: Int32 { get }
    /// Creates a transaction holding no operations and commits it.
    func commitEmptyTransaction() -> TransactionAttempt
}

typealias DoctorProbeBackend = WindowServerConnectionReading

enum DoctorProbes {
    /// Every probe, in report order.
    static func run(_ backend: DoctorProbeBackend) -> [ProbeResult] {
        [
            ProbeResult(name: "windowserver", verdict: windowServerConnection(backend)),
        ]
    }

    // MARK: Reporting

    static func line(_ result: ProbeResult) -> String {
        switch result.verdict {
        case .works(let detail):        return "✅ \(result.name): \(detail)"
        case .failed(let detail):       return "❌ \(result.name): \(detail)"
        case .inconclusive(let detail): return "⚠️  \(result.name): \(detail)"
        }
    }

    /// One line per probe, then the summary line.
    static func report(_ results: [ProbeResult]) -> [String] {
        results.map(line) + [summary(results)]
    }

    static func summary(_ results: [ProbeResult]) -> String {
        var works = 0, failed = 0, inconclusive = 0
        for result in results {
            switch result.verdict {
            case .works:        works += 1
            case .failed:       failed += 1
            case .inconclusive: inconclusive += 1
            }
        }
        return "doctor: \(works) works, \(failed) failed, \(inconclusive) inconclusive"
    }

    /// Failed probes count toward doctor's exit status; inconclusive ones do not.
    static func issueCount(_ results: [ProbeResult]) -> Int {
        results.filter { if case .failed = $0.verdict { return true } else { return false } }.count
    }

    // MARK: WindowServer connection

    /// The connection id must be nonzero and an empty transaction must commit
    /// without faulting. SLSTransactionCommit has no result to judge.
    static func windowServerConnection(_ backend: WindowServerConnectionReading) -> ProbeVerdict {
        let cid = backend.connectionID
        guard cid != 0 else {
            return .failed("SLSMainConnectionID returned 0: no WindowServer connection")
        }
        switch backend.commitEmptyTransaction() {
        case .unavailable:
            return .failed("SLSTransactionCreate or SLSTransactionCommit does not resolve")
        case .createFailed:
            return .failed("SLSTransactionCreate returned no transaction on connection \(cid)")
        case .committed:
            return .works("connection \(cid) open; an empty transaction commits")
        }
    }
}

/// The readers `stackd doctor` probes with: the same paths the daemon uses.
struct LiveDoctorBackend: DoctorProbeBackend {
    var connectionID: Int32 { SkyLight.cid }

    func commitEmptyTransaction() -> TransactionAttempt {
        guard let create = WindowTransaction.create, let commit = WindowTransaction.commit else {
            return .unavailable
        }
        guard let transaction = create(SkyLight.cid)?.takeRetainedValue() else { return .createFailed }
        commit(transaction, 0)
        return .committed
    }
}
