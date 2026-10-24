import ApplicationServices
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

/// A window as CGWindowList lists it.
struct ListedWindow: Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let layer: Int
    /// Global display coordinates, top-left origin, points.
    let bounds: CGRect
}

/// The two places a window's bounds can be read: CGWindowList and the window
/// server itself (`Overlay.bounds(of:)`, the read overlays track windows by).
protocol WindowBoundsReading {
    /// The probing process, whose windows are never sampled.
    var ownPID: pid_t { get }
    /// The probing process's name: the running daemon owns windows under it too.
    var ownName: String { get }
    /// On-screen windows, front to back.
    func onScreenWindows() -> [ListedWindow]
    /// nil when the window server rejects the id.
    func serverBounds(of id: CGWindowID) -> CGRect?
}

/// The managed display and space list behind `sd.spaces`.
protocol SpacesReading {
    /// The number of spaces on each display SLSCopyManagedDisplaySpaces lists.
    func spaceCountsByDisplay() -> [Int]
}

/// What one AXExtrasMenuBar read of the menu bar's status items returned.
enum StatusItemRead: Equatable {
    case items(Int)
    /// Answered, with no item in it.
    case empty
    /// The AXError code of a refused read.
    case refused(Int32)
}

/// The two routes to the menu bar's status items (`MenubarItems`): one
/// system-wide AXExtrasMenuBar read, or each running process asked for its
/// own. Newer macOS releases refuse the first.
protocol StatusItemReading {
    var accessibilityTrusted: Bool { get }
    func systemWideStatusItems() -> StatusItemRead
    /// Only called once the system-wide read yielded nothing: it asks every
    /// running process, which is slow.
    func perProcessStatusItems() -> StatusItemRead
}

typealias DoctorProbeBackend = WindowServerConnectionReading & WindowBoundsReading & SpacesReading
    & StatusItemReading

enum DoctorProbes {
    /// Every probe, in report order.
    static func run(_ backend: DoctorProbeBackend) -> [ProbeResult] {
        [
            ProbeResult(name: "windowserver", verdict: windowServerConnection(backend)),
            ProbeResult(name: "window-bounds", verdict: windowBounds(backend)),
            ProbeResult(name: "spaces", verdict: spaces(backend)),
            ProbeResult(name: "status-items", verdict: statusItems(backend)),
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

extension DoctorProbes {
    static let boundsSampleLimit = 3
    /// Points. The two reads are taken a moment apart and round differently.
    static let boundsTolerance: CGFloat = 1

    /// For up to three on-screen layer-0 windows, the window server's bounds
    /// must equal CGWindowList's. A window can move between the two reads, so
    /// a disagreement is checked once more before it is reported.
    static func windowBounds(_ backend: WindowBoundsReading) -> ProbeVerdict {
        var pass = compareBounds(backend)
        if !pass.problems.isEmpty {
            let second = compareBounds(backend)
            if second.checked > 0 { pass = second }
        }
        guard pass.checked > 0 else { return .inconclusive("no on-screen window to compare") }
        guard pass.problems.isEmpty else { return .failed(pass.problems.joined(separator: "; ")) }
        return .works("SLSGetWindowBounds matches CGWindowList within \(Int(boundsTolerance)) pt for \(pass.checked) window(s)")
    }

    static func boundsAgree(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= boundsTolerance && abs(a.minY - b.minY) <= boundsTolerance
            && abs(a.width - b.width) <= boundsTolerance && abs(a.height - b.height) <= boundsTolerance
    }

    private static func compareBounds(_ backend: WindowBoundsReading) -> (checked: Int, problems: [String]) {
        let samples = backend.onScreenWindows()
            .filter { window in
                window.layer == 0
                    && window.ownerPID != backend.ownPID && window.ownerName != backend.ownName
                    && window.bounds.width > 0 && window.bounds.height > 0
            }
            .prefix(boundsSampleLimit)
        var problems: [String] = []
        for window in samples {
            let label = "window \(window.id) (\(window.ownerName))"
            guard let server = backend.serverBounds(of: window.id) else {
                problems.append("\(label): SLSGetWindowBounds read failed")
                continue
            }
            if !boundsAgree(window.bounds, server) {
                problems.append("\(label): CGWindowList \(describe(window.bounds)) vs SLSGetWindowBounds \(describe(server))")
            }
        }
        return (samples.count, problems)
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "%g,%g %gx%g", rect.minX, rect.minY, rect.width, rect.height)
    }
}

extension DoctorProbes {
    /// SLSCopyManagedDisplaySpaces must list a display that has a space.
    static func spaces(_ backend: SpacesReading) -> ProbeVerdict {
        let counts = backend.spaceCountsByDisplay()
        guard !counts.isEmpty else {
            return .failed("SLSCopyManagedDisplaySpaces returned no displays")
        }
        let total = counts.reduce(0, +)
        guard total > 0 else {
            return .failed("SLSCopyManagedDisplaySpaces listed \(counts.count) display(s) but no space")
        }
        return .works("\(counts.count) display(s), \(total) space(s)")
    }
}

extension DoctorProbes {
    /// Names the route that returns the menu bar's status items on this macOS.
    /// Both reads need Accessibility; without it nothing can be judged.
    static func statusItems(_ backend: StatusItemReading) -> ProbeVerdict {
        guard backend.accessibilityTrusted else {
            return .inconclusive("Accessibility is not granted to this process, so the status-item reads cannot run")
        }
        let systemWide = backend.systemWideStatusItems()
        if case .items(let count) = systemWide {
            return .works("system-wide AXExtrasMenuBar returned \(count) item(s)")
        }
        let why: String
        switch systemWide {
        case .refused(let code): why = "refused (AXError \(code))"
        default:                 why = "returned no items"
        }
        if case .items(let count) = backend.perProcessStatusItems() {
            return .works("per-process AXExtrasMenuBar fallback found \(count) item(s); the system-wide read \(why)")
        }
        return .failed("no status item readable: the system-wide read \(why) and the per-process fallback found none")
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

    var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }
    var ownName: String { ProcessInfo.processInfo.processName }

    func onScreenWindows() -> [ListedWindow] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return ListedWindow(id: id, ownerPID: pid,
                                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                                layer: layer, bounds: bounds)
        }
    }

    func serverBounds(of id: CGWindowID) -> CGRect? { Overlay.bounds(of: id) }

    func spaceCountsByDisplay() -> [Int] {
        Spaces.all().values.map { (($0 as? [String: Any])?["spaces"] as? [Any])?.count ?? 0 }
    }

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func systemWideStatusItems() -> StatusItemRead {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(systemWide, "AXExtrasMenuBar" as CFString, &value)
        guard error == .success else { return .refused(error.rawValue) }
        guard let bar = AX.element(from: value) else { return .empty }
        AXUIElementSetMessagingTimeout(bar, 0.5)
        let count = AX.children(of: bar, timeout: 0.5).count
        return count > 0 ? .items(count) : .empty
    }

    /// Runs the daemon's own read with nothing cached, so every running
    /// process is asked. The caller has already seen the system-wide read
    /// come up empty, which sends the read down its per-process route.
    func perProcessStatusItems() -> StatusItemRead {
        var ownerCache: [pid_t: String] = [:]
        var candidates = MenubarExtrasCandidates()
        let count = MenubarItems.items(ownerCache: &ownerCache, candidates: &candidates).count
        return count > 0 ? .items(count) : .empty
    }
}
