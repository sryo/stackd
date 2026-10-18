import Foundation

// Host.loadSnapshot is read once per subscribed stack on every tick, so the
// CPU figures must not depend on how many callers there are or how closely
// they follow one another.

func registerHostLoadTests() {
    func ticks(_ user: UInt64, _ system: UInt64, _ idle: UInt64, _ nice: UInt64 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    // MARK: - CPULoadSampler

    test("CPULoadSampler: the first sample only seeds the baseline") {
        var sampler = CPULoadSampler()
        try expect(sampler.sample(ticks(100, 50, 850), at: 10) == nil)
    }

    test("CPULoadSampler: fractions cover the ticks since the baseline") {
        var sampler = CPULoadSampler()
        _ = sampler.sample(ticks(100, 50, 850), at: 10)
        let load = sampler.sample(ticks(130, 60, 910), at: 12)
        try expectEqual(load?["user"], 0.3)
        try expectEqual(load?["system"], 0.1)
        try expectEqual(load?["idle"], 0.6)
        try expectEqual(load?["total"], 0.4)
    }

    test("CPULoadSampler: nice time counts as user time") {
        var sampler = CPULoadSampler()
        _ = sampler.sample(ticks(0, 0, 0, 0), at: 0)
        let load = sampler.sample(ticks(20, 10, 60, 10), at: 2)
        try expectEqual(load?["user"], 0.3)
        try expectEqual(load?["idle"], 0.6)
    }

    test("CPULoadSampler: a sample right after another repeats its fractions") {
        var sampler = CPULoadSampler()
        _ = sampler.sample(ticks(100, 50, 850), at: 10)
        let first = sampler.sample(ticks(130, 60, 910), at: 12)
        let second = sampler.sample(ticks(130, 61, 911), at: 12.002)
        try expect(first != nil)
        try expectEqual(second ?? [:], first ?? [:])
    }

    test("CPULoadSampler: a sample inside the window leaves the baseline where it was") {
        var sampler = CPULoadSampler()
        _ = sampler.sample(ticks(0, 0, 0), at: 0)
        _ = sampler.sample(ticks(30, 10, 60), at: 2)
        _ = sampler.sample(ticks(35, 12, 63), at: 2.01)
        // Measured from the t=2 baseline: user 20, system 0, idle 80.
        let load = sampler.sample(ticks(50, 10, 140), at: 4)
        try expectEqual(load?["user"], 0.2)
        try expectEqual(load?["system"], 0)
        try expectEqual(load?["idle"], 0.8)
    }

    test("CPULoadSampler: a second sample inside the first window has nothing to report yet") {
        var sampler = CPULoadSampler()
        _ = sampler.sample(ticks(0, 0, 0), at: 0)
        try expect(sampler.sample(ticks(5, 5, 90), at: 0.01) == nil)
    }

    test("CPULoadSampler: a window with no ticks reports nothing") {
        var sampler = CPULoadSampler()
        _ = sampler.sample(ticks(10, 10, 80), at: 0)
        try expect(sampler.sample(ticks(10, 10, 80), at: 2) == nil)
    }

    // MARK: - Host.loadSnapshot

    test("Host.loadSnapshot: back-to-back callers see the same sane cpu fractions") {
        // The first reading seeds the process-wide baseline; wait for the first full window.
        var primed = false
        let deadline = Date().addingTimeInterval(10)
        while !primed && Date() < deadline {
            primed = Host.loadSnapshot() != nil
            if !primed { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard primed else { throw Expectation(message: "loadSnapshot never produced a cpu diff") }

        let first = Host.loadSnapshot()?["cpu"] as? [String: Double]
        let second = Host.loadSnapshot()?["cpu"] as? [String: Double]
        guard let a = first, let b = second else {
            throw Expectation(message: "a caller got no cpu fractions: \(String(describing: first)) / \(String(describing: second))")
        }
        try expectEqual(a, b)
        for key in ["user", "system", "idle", "total"] {
            let v = a[key] ?? -1
            try expect(v >= 0 && v <= 1.001, "cpu.\(key) out of [0,1], got \(v)")
        }
        try expect(abs(a["user"]! + a["system"]! + a["idle"]! - 1) < 0.01, "fractions should sum to 1")
    }
}
