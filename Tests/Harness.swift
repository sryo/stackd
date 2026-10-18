import Foundation

struct TestCase {
    let name: String
    let site: String
    let body: () throws -> Void
}

/// Registered tests in registration order. Names are unique: `--filter` and
/// `--exclude` select by name, and two tests sharing one make a failure line
/// ambiguous.
struct TestRegistry {
    enum Outcome: Equatable {
        case added
        /// The name was taken; `firstSite` is where it was first registered.
        case duplicate(firstSite: String)
    }

    private(set) var cases: [TestCase] = []
    private var firstSite: [String: String] = [:]

    mutating func add(_ name: String, site: String, _ body: @escaping () throws -> Void) -> Outcome {
        if let first = firstSite[name] { return .duplicate(firstSite: first) }
        firstSite[name] = site
        cases.append(TestCase(name: name, site: site, body: body))
        return .added
    }
}

private var registry = TestRegistry()

/// A repeated name stops the run before any test executes (exit status 2,
/// the same as a bad flag), so it is fixed where it is introduced.
func test(_ name: String, file: StaticString = #file, line: UInt = #line,
          _ body: @escaping () throws -> Void) {
    let site = "\(file):\(line)"
    if case .duplicate(let first) = registry.add(name, site: site, body) {
        print("duplicate test name '\(name)'\n  registered at \(first)\n  and again at \(site)")
        exit(2)
    }
}

struct Expectation: Error { let message: String }

func expect(_ cond: @autoclosure () -> Bool, _ msg: String = "expectation failed",
            file: StaticString = #file, line: UInt = #line) throws {
    if !cond() { throw Expectation(message: "\(file):\(line): \(msg)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String = "",
                               file: StaticString = #file, line: UInt = #line) throws {
    if actual != expected {
        let prefix = msg.isEmpty ? "" : "\(msg): "
        throw Expectation(message: "\(file):\(line): \(prefix)expected \(expected), got \(actual)")
    }
}

// MARK: - Waiting on the main run loop

/// Pumps the main run loop until `done()` holds or `timeout` seconds pass, so
/// work queued on main (DispatchQueue.main, timers, WebKit and Vision
/// completions) can run. Returns whether `done()` held when it stopped.
///
/// A positive wait should give `timeout` real headroom over the event it waits
/// for: it returns the moment `done()` holds, so slack costs nothing on a pass.
@discardableResult
func spin(timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        let now = Date()
        if now >= deadline { return false }
        RunLoop.main.run(mode: .default, before: min(deadline, now.addingTimeInterval(0.005)))
    }
    return true
}

/// Pumps the main run loop for a fixed span, for letting queued work land
/// when there is no condition to wait on.
func spin(for seconds: TimeInterval) {
    spin(timeout: seconds) { false }
}

/// Returns once every block already queued on the main queue has run. The
/// queue is FIFO, so a marker block queued now runs after them: a check that
/// something was never delivered can wait on this instead of sleeping.
/// Delayed work (`asyncAfter`, timers) is not covered.
func drainMainQueue() {
    var reached = false
    DispatchQueue.main.async { reached = true }
    spin(timeout: 30) { reached }
}

// MARK: - Running

/// A test at least this slow prints its duration beside its name.
let slowTestThreshold: TimeInterval = 1.0
/// A test still running after this long says so on stderr, repeating at the
/// same interval, so a hang names itself.
let hangAnnounceInterval: TimeInterval = 30

/// One result line: the mark and name, plus the duration for a slow test.
func resultLine(_ mark: String, _ name: String, seconds: TimeInterval) -> String {
    seconds >= slowTestThreshold ? "\(mark) \(name) (\(String(format: "%.2f", seconds))s)" : "\(mark) \(name)"
}

/// Announces a test that has not finished. The timer runs off the main thread,
/// so it still fires while a test blocks main.
private final class HangWatch {
    private let timer = DispatchSource.makeTimerSource(queue: .global())

    init(name: String) {
        let started = DispatchTime.now()
        timer.schedule(deadline: .now() + hangAnnounceInterval, repeating: hangAnnounceInterval)
        timer.setEventHandler {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            FileHandle.standardError.write(Data("… still running after \(Int(elapsed))s: \(name)\n".utf8))
        }
        timer.resume()
    }

    func cancel() { timer.cancel() }
}

func runAll(include: NSRegularExpression? = nil, exclude: NSRegularExpression? = nil) -> Int32 {
    func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    var failed = 0
    var ran = 0
    var skipped = 0
    var slow: [(name: String, seconds: TimeInterval)] = []
    for t in registry.cases {
        if let inc = include, !matches(inc, t.name) { skipped += 1; continue }
        if let exc = exclude,  matches(exc, t.name) { skipped += 1; continue }
        ran += 1
        let watch = HangWatch(name: t.name)
        let started = DispatchTime.now()
        var failure: String?
        do {
            try t.body()
        } catch let e as Expectation {
            failure = e.message
        } catch {
            failure = "unexpected: \(error)"
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        watch.cancel()
        if seconds >= slowTestThreshold { slow.append((t.name, seconds)) }
        if let failure = failure {
            print("\(resultLine("✗", t.name, seconds: seconds))\n  \(failure)")
            failed += 1
        } else {
            print(resultLine("✓", t.name, seconds: seconds))
        }
    }
    if !slow.isEmpty {
        print("slowest of \(slow.count) tests over \(Int(slowTestThreshold))s:")
        for s in slow.sorted(by: { $0.seconds > $1.seconds }).prefix(5) {
            print("  \(String(format: "%.2f", s.seconds))s  \(s.name)")
        }
    }
    print("———")
    let skipNote = skipped > 0 ? " (\(skipped) skipped)" : ""
    if ran == 0 {
        // A filter that matches nothing is a typo, not a pass.
        print("no tests matched\(skipNote)")
        return 2
    }
    print(failed == 0 ? "\(ran) passed\(skipNote)" : "\(failed)/\(ran) failed\(skipNote)")
    // The exit status is 8 bits wide: 256 failures would wrap to success.
    return failed == 0 ? 0 : 1
}
