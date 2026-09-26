import Foundation

// Tests for `Host.diskIO()` and its pure rate-calculation helper.
//
// Two layers:
//   1. `computeRate` — pure before/after/elapsed math and its degenerate
//      cases (zero/negative elapsed, counter reset).
//   2. `diskIO()` — real IOKit walk over IOBlockStorageDriver matches. Every
//      Mac has at least one (the boot disk), so we can characterize shape,
//      key presence, and the seed-then-deltas sampling progression without
//      mocking, but not byte magnitudes.

func registerHostDiskIOTests() {
    // MARK: - computeRate (pure)

    test("computeRate is delta bytes / elapsed seconds") {
        try expectEqual(Host.computeRate(before: 0, after: 1_048_576, elapsed: 1.0), 1_048_576.0)
        try expectEqual(Host.computeRate(before: 0, after: 10_485_760, elapsed: 2.0), 5_242_880.0)
        try expectEqual(Host.computeRate(before: 0, after: 512, elapsed: 0.5), 1024.0)
        try expectEqual(Host.computeRate(before: 42_000, after: 42_000, elapsed: 1.0), 0.0)
        // 4 GiB across 8s — the UInt64 → Double hop must not truncate.
        try expectEqual(Host.computeRate(before: 0, after: 4 * 1024 * 1024 * 1024, elapsed: 8.0), 536_870_912.0)
    }

    test("computeRate returns 0 for zero or negative elapsed") {
        // Two reads inside the same tick, or a clock step backward.
        try expectEqual(Host.computeRate(before: 0, after: 1_000, elapsed: 0.0), 0.0)
        try expectEqual(Host.computeRate(before: 0, after: 1_000, elapsed: -1.0), 0.0)
    }

    test("computeRate returns 0 when the counter goes backward (device remount)") {
        // A device that ejects/remounts between samples resets its counters.
        try expectEqual(Host.computeRate(before: 1_000_000, after: 500, elapsed: 1.0), 0.0)
    }

    // MARK: - diskIO() shape (real IOKit, real boot disk)

    test("diskIO returns ≥1 entry, each with name + cumulative byte/op counters") {
        // Every Mac has at least the boot disk's IOBlockStorageDriver node;
        // empty means the IOKit walk regressed. Cumulative counters are
        // always present (rate fields are optional). `name` is the BSD identifier
        // ("disk0", "disk1s2") that users see in `diskutil list`.
        let entries = Host.diskIO()
        try expect(!entries.isEmpty, "no disks enumerated")
        for e in entries {
            try expect(e["name"] is String, "name should be a String (BSD identifier): \(e)")
            for key in ["bytesRead", "bytesWritten", "opsRead", "opsWritten"] {
                try expect(e[key] is UInt64, "\(key) should be UInt64: \(e)")
            }
        }
    }

    test("diskIO entry names are unique per device (one row per BSD disk)") {
        // The previous-sample dict is keyed by BSD name; duplicates would
        // silently collapse rate calculations between unrelated devices.
        let entries = Host.diskIO()
        let names = entries.compactMap { $0["name"] as? String }
        try expectEqual(names.count, entries.count)
        try expectEqual(Set(names).count, names.count)
    }

    test("diskIO second call emits finite, non-negative per-second rates") {
        // Sampling contract: first call seeds the baseline (no rate fields),
        // second call computes deltas against it. Don't assert magnitudes —
        // back-to-back calls within milliseconds yield tiny but well-defined
        // numbers. Just verify the shape upgrades and the values are sane.
        _ = Host.diskIO()
        let second = Host.diskIO()
        guard let entry = second.first else {
            throw Expectation(message: "no disks on second call")
        }
        guard let readRate = entry["bytesReadPerSecond"] as? Double else {
            throw Expectation(message: "expected bytesReadPerSecond Double after second call, got \(String(describing: entry["bytesReadPerSecond"]))")
        }
        guard let writeRate = entry["bytesWrittenPerSecond"] as? Double else {
            throw Expectation(message: "expected bytesWrittenPerSecond Double after second call, got \(String(describing: entry["bytesWrittenPerSecond"]))")
        }
        try expect(readRate.isFinite && readRate >= 0, "readRate must be finite + non-negative, got \(readRate)")
        try expect(writeRate.isFinite && writeRate >= 0, "writeRate must be finite + non-negative, got \(writeRate)")
    }
}
