import Foundation

// Tests for the pure rate-calculation helper that drives `sd.host.diskIO`.
// The IOKit walk itself (IOServiceGetMatchingServices + IORegistryEntry
// property reads) is impure — it talks to live block-device hardware and
// can't be meaningfully unit-tested. The rate math, however, is a pure
// before/after delta divided by elapsed seconds, and it's the only piece
// where regressions would silently corrupt every consumer's number.
//
// Pattern mirrors UpdateParserTests: extract the bug-prone surface as a
// static helper, hammer it here, leave the I/O path uncovered by design.

func registerHostDiskIOTests() {
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
}
