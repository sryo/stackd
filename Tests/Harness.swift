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

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               file: StaticString = #file, line: UInt = #line) throws {
    if actual != expected {
        throw Expectation(message: "\(file):\(line): expected \(expected), got \(actual)")
    }
}

func runAll() -> Int32 {
    var failed = 0
    for t in registry {
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
    print(failed == 0 ? "\(registry.count) passed" : "\(failed)/\(registry.count) failed")
    return Int32(failed)
}
