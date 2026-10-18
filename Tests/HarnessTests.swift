import Foundation

// The harness itself: the registry that refuses a repeated test name, the
// main-run-loop wait the async tests share, and the result line format. The
// refusal's exit path (print, exit status 2) is `test(_:_:)`; the decision
// behind it is `TestRegistry.add`, which is what is exercised here.

func registerHarnessTests() {
    test("harness: the registry keeps tests in registration order") {
        var registry = TestRegistry()
        for name in ["b", "a", "c"] {
            try expectEqual(registry.add(name, site: "t.swift:1") {}, .added)
        }
        try expectEqual(registry.cases.map { $0.name }, ["b", "a", "c"])
    }

    test("harness: the registry refuses a repeated name and names where it was first registered") {
        var registry = TestRegistry()
        _ = registry.add("same name", site: "A.swift:10") {}
        try expectEqual(registry.add("same name", site: "B.swift:20") {}, .duplicate(firstSite: "A.swift:10"))
        try expectEqual(registry.cases.count, 1, "the repeated test must not be added")
        try expectEqual(registry.cases.first?.site, "A.swift:10")
    }

    test("harness: names that differ only by case or a trailing space are distinct tests") {
        var registry = TestRegistry()
        for name in ["x", "X", "x "] {
            try expectEqual(registry.add(name, site: "t.swift:1") {}, .added, "'\(name)'")
        }
    }

    test("harness: spin returns as soon as the condition holds, well before the timeout") {
        let started = Date()
        var polls = 0
        let held = spin(timeout: 30) { polls += 1; return polls >= 3 }
        try expect(held, "the condition became true, so spin must report it")
        try expect(Date().timeIntervalSince(started) < 5, "spin waited out its timeout instead of returning")
    }

    test("harness: spin gives up at the timeout and reports that the condition never held") {
        let started = Date()
        let held = spin(timeout: 0.1) { false }
        let elapsed = Date().timeIntervalSince(started)
        try expect(!held, "an unmet condition must report false")
        try expect(elapsed >= 0.1, "returned after \(elapsed)s, before the 0.1s timeout")
        try expect(elapsed < 2, "overshot a 0.1s timeout by \(elapsed)s")
    }

    test("harness: spin runs work queued on the main queue") {
        var ran = false
        DispatchQueue.main.async { ran = true }
        try expect(spin(timeout: 5) { ran }, "a main-queue block never ran while spinning")
    }

    test("harness: spin(for:) lets a delayed main-queue block land") {
        var ran = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { ran = true }
        spin(for: 0.3)
        try expect(ran, "a 20ms asyncAfter block did not run within a 300ms spin")
    }

    test("harness: drainMainQueue runs everything already queued on main, in order") {
        var order: [Int] = []
        for i in 0..<5 { DispatchQueue.main.async { order.append(i) } }
        drainMainQueue()
        try expectEqual(order, [0, 1, 2, 3, 4])
    }

    test("harness: a fast test prints only its name, a slow one adds its duration") {
        try expectEqual(resultLine("✓", "quick", seconds: 0.2), "✓ quick")
        try expectEqual(resultLine("✓", "slow one", seconds: 1.234), "✓ slow one (1.23s)")
        try expectEqual(resultLine("✗", "slow failure", seconds: 12), "✗ slow failure (12.00s)")
        try expectEqual(resultLine("✓", "at the threshold", seconds: slowTestThreshold),
                        "✓ at the threshold (1.00s)")
    }
}
