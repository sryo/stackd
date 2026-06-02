import Foundation

// Tests for `Host.diskIO()` and its pure rate-calculation helper.
//
// Two layers:
//   1. `computeRate` — pure before/after/elapsed math. Hammer the edge cases
//      (zero/negative elapsed, counter reset, fractional time, large deltas).
//   2. `diskIO()` — real IOKit walk over IOBlockStorageDriver matches. Every
//      Mac has at least one (the boot disk), so we can characterize shape,
//      key presence, and the seed-then-deltas sampling progression without
//      mocking. We can't assert specific byte magnitudes, but we can assert
//      the per-device dictionary contract.
//
// Pattern mirrors UpdateParserTests: extract the bug-prone math as a static
// helper, hammer it, then layer integration-style shape checks on top.

func registerHostDiskIOTests() {
    // MARK: - computeRate (pure)

    test("computeRate returns positive bytes/sec for a forward delta") {
        // 1 MiB written across 1.0s → 1_048_576 B/s.
        let rate = Host.computeRate(before: 0, after: 1_048_576, elapsed: 1.0)
        try expectEqual(rate, 1_048_576.0)
    }

    test("computeRate scales by elapsed seconds") {
        // 10 MiB across 2.0s → 5 MiB/s.
        let rate = Host.computeRate(before: 0, after: 10_485_760, elapsed: 2.0)
        try expectEqual(rate, 5_242_880.0)
    }

    test("computeRate returns 0 when before == after (idle device)") {
        let rate = Host.computeRate(before: 42_000, after: 42_000, elapsed: 1.0)
        try expectEqual(rate, 0.0)
    }

    test("computeRate returns 0 when elapsed is zero (degenerate sample)") {
        // Two reads inside the same monotonic tick — divide-by-zero guard.
        let rate = Host.computeRate(before: 0, after: 1_000, elapsed: 0.0)
        try expectEqual(rate, 0.0)
    }

    test("computeRate returns 0 when elapsed is negative (clock skew)") {
        // System clock jump backward shouldn't produce a negative or
        // explosive positive rate; clamp to 0 and let the next sample
        // re-baseline cleanly.
        let rate = Host.computeRate(before: 0, after: 1_000, elapsed: -1.0)
        try expectEqual(rate, 0.0)
    }

    test("computeRate returns 0 on counter wraparound (after < before)") {
        // BSD I/O byte counters are UInt64 on macOS — they don't wrap in any
        // realistic lifetime, but a device that ejects/remounts between
        // samples can reset to 0. Surface as 0, not a huge negative.
        let rate = Host.computeRate(before: 1_000_000, after: 500, elapsed: 1.0)
        try expectEqual(rate, 0.0)
    }

    test("computeRate handles fractional elapsed cleanly") {
        // 512 B across 0.5s → 1024 B/s.
        let rate = Host.computeRate(before: 0, after: 512, elapsed: 0.5)
        try expectEqual(rate, 1024.0)
    }

    test("computeRate handles large multi-GB deltas without overflow") {
        // 4 GiB across 8.0s → 512 MiB/s. Verifies the UInt64 → Double hop
        // doesn't truncate within realistic NVMe burst-write magnitudes.
        let before: UInt64 = 0
        let after:  UInt64 = 4 * 1024 * 1024 * 1024
        let rate = Host.computeRate(before: before, after: after, elapsed: 8.0)
        try expectEqual(rate, 536_870_912.0)
    }

    // MARK: - diskIO() shape (real IOKit, real boot disk)

    test("diskIO returns at least one block-device entry on real hardware") {
        // Every Mac has at least the boot disk's IOBlockStorageDriver node.
        // An empty array means either the IOKit walk regressed or the
        // matching dict no longer resolves — both are bugs worth catching.
        let entries = Host.diskIO()
        try expect(!entries.isEmpty, "expected ≥1 IOBlockStorageDriver match, got 0")
    }

    test("diskIO entries always expose name + cumulative byte/op counters") {
        // Cumulative counters are always present (Statistics dict is read
        // before the optional rate fields). `name` is the BSD identifier
        // ("disk0", "disk1s2") that users see in `diskutil list`.
        let entries = Host.diskIO()
        guard let first = entries.first else {
            throw Expectation(message: "no disks enumerated")
        }
        try expect(first["name"] is String, "name should be a String (BSD identifier)")
        try expect(first["bytesRead"] is UInt64, "bytesRead should be UInt64")
        try expect(first["bytesWritten"] is UInt64, "bytesWritten should be UInt64")
        try expect(first["opsRead"] is UInt64, "opsRead should be UInt64")
        try expect(first["opsWritten"] is UInt64, "opsWritten should be UInt64")
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
