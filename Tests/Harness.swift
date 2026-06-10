import Foundation

private struct TestCase { let name: String; let body: () throws -> Void }
private var registry: [TestCase] = []

func test(_ name: String, _ body: @escaping () throws -> Void) {
    registry.append(TestCase(name: name, body: body))
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

func runAll(include: NSRegularExpression? = nil, exclude: NSRegularExpression? = nil) -> Int32 {
    func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    var failed = 0
    var ran = 0
    var skipped = 0
    for t in registry {
        if let inc = include, !matches(inc, t.name) { skipped += 1; continue }
        if let exc = exclude,  matches(exc, t.name) { skipped += 1; continue }
        ran += 1
        do {
            try t.body()
            print("✓ \(t.name)")
        } catch let e as Expectation {
            print("✗ \(t.name)\n  \(e.message)")
            failed += 1
        } catch {
            print("✗ \(t.name)\n  unexpected: \(error)")
            failed += 1
        }
    }
    print("———")
    let skipNote = skipped > 0 ? " (\(skipped) skipped)" : ""
    print(failed == 0 ? "\(ran) passed\(skipNote)" : "\(failed)/\(ran) failed\(skipNote)")
    return Int32(failed)
}
