import Foundation

// =====================================================================
// MARK: - Intake trace
// =====================================================================

/// Fixed-capacity ring: appends overwrite the oldest element once full.
struct TraceRing<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0
    /// Elements lost to wraparound.
    private(set) var overwritten = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
            return
        }
        storage[head] = e
        head = (head + 1) % capacity
        overwritten += 1
    }

    /// Oldest first.
    var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }
}

/// One drained intake item: its kind, how long its first event waited
/// between the callback's post and the drain (`queueUs`), how long its
/// handler ran (`handlerUs`), and how many events merged into it.
struct IntakeTraceRecord: Equatable {
    let kind: IntakeKind
    let enqueuedNs: UInt64
    let queueUs: Double
    let handlerUs: Double
    let merged: Int
}

/// Times intake items into a TraceRing. Disabled, it never reads the
/// clock: `stamp()` is nil, so posts carry no enqueue time, and
/// `measure` runs the handler bare. A class so a handler that re-enters
/// the drain (a nested run loop) doesn't overlap an exclusive access.
final class IntakeTracer {
    let enabled: Bool
    private let clock: () -> UInt64
    private(set) var ring: TraceRing<IntakeTraceRecord>

    static func enabledFromEnv(_ env: [String: String]) -> Bool {
        env["STACKD_TRACE"] == "1"
    }

    /// Uptime in ns, the clock intake timings use.
    static func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    init(enabled: Bool, capacity: Int, clock: @escaping () -> UInt64 = IntakeTracer.uptimeNs) {
        self.enabled = enabled
        self.clock = clock
        self.ring = TraceRing(capacity: enabled ? capacity : 1)
    }

    /// The enqueue time for a post, nil while disabled.
    func stamp() -> UInt64? { enabled ? clock() : nil }

    /// Run `body`, recording it when tracing and the item has an enqueue
    /// time.
    func measure(_ kind: IntakeKind, enqueued: UInt64?, merged: Int, _ body: () -> Void) {
        guard enabled, let enq = enqueued else { body(); return }
        let start = clock()
        body()
        let end = clock()
        ring.append(IntakeTraceRecord(
            kind: kind, enqueuedNs: enq,
            queueUs: Self.us(from: enq, to: start),
            handlerUs: Self.us(from: start, to: end),
            merged: merged))
    }

    private static func us(from a: UInt64, to b: UInt64) -> Double {
        b > a ? Double(b - a) / 1000 : 0
    }
}

/// The trace file the bench collects.
enum IntakeTraceDump {
    static func path(env: [String: String], home: String) -> String {
        if let p = env["STACKD_TRACE_PATH"], !p.isEmpty { return p }
        return home + "/Library/Logs/stackd-trace.json"
    }

    /// `t_us` is the first event's enqueue time, uptime µs.
    static func json(_ ring: TraceRing<IntakeTraceRecord>, pid: Int32) -> Data {
        let records: [[String: Any]] = ring.elements.map { r in
            ["kind": r.kind.name,
             "t_us": Double(r.enqueuedNs) / 1000,
             "queue_us": r.queueUs,
             "handler_us": r.handlerUs,
             "merged": r.merged]
        }
        let obj: [String: Any] = [
            "version": 1,
            "pid": Int(pid),
            "capacity": ring.capacity,
            "overwritten": ring.overwritten,
            "records": records,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// STACKD_TRACE=1: WindowServerIntake times every drained item into a ring
/// of the last `capacity` items, written as JSON to
/// `~/Library/Logs/stackd-trace.json` (or STACKD_TRACE_PATH) on SIGUSR1,
/// on SIGTERM (which then exits) and at normal termination.
enum IntakeTrace {
    static let capacity = 32_768
    static let enabled = IntakeTracer.enabledFromEnv(ProcessInfo.processInfo.environment)

    private static var sources: [DispatchSourceSignal] = []

    /// Main thread, once at launch.
    static func installDumpTriggers() {
        guard enabled, sources.isEmpty else { return }
        for sig in [SIGUSR1, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                dump()
                if sig == SIGTERM { exit(0) }
            }
            src.resume()
            sources.append(src)
        }
        log("trace: intake tracing on; dump on SIGUSR1 / exit to \(dumpPath)")
    }

    static var dumpPath: String {
        IntakeTraceDump.path(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    /// Write the ring. Main thread.
    static func dump() {
        guard enabled else { return }
        let ring = WindowServerIntake.traceRing
        let data = IntakeTraceDump.json(ring, pid: getpid())
        do {
            try data.write(to: URL(fileURLWithPath: dumpPath), options: .atomic)
            log("trace: wrote \(ring.count) records to \(dumpPath)")
        } catch {
            log("trace: write to \(dumpPath) failed: \(error)")
        }
    }
}
