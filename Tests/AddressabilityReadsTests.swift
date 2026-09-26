import Foundation
import CoreGraphics

// AddressabilityReads — the off-main schedule for WindowAddressabilityCache
// probes. One AX read in flight per window: a hung app backs up one read per
// window, never one per Windows.all() pass. Generations let an invalidation
// (window destroyed, app quit) discard a read that was already running, and
// a staleness mark (space change, wake) re-run it instead of trusting a
// reading taken before the change.
//
// WindowAddressabilityCache.lookup / record — what callers see while a read
// is pending, and how a finished read turns into a cached verdict.
func registerAddressabilityReadsTests() {
    test("AddressabilityReads — a request while one is in flight starts nothing") {
        var r = AddressabilityReads<Int>()
        _ = r.request(1)
        try expect(r.request(1) == nil, "a hung app must not queue a read per Windows.all() pass")
        try expect(r.request(2) != nil, "windows are independent")
    }

    test("AddressabilityReads — resolving applies the reading and frees the key") {
        var r = AddressabilityReads<Int>()
        let g = r.request(1)!
        try expectEqual(r.resolved(1, generation: g), .apply)
        try expect(r.request(1) != nil, "after resolution the next pass may read again")
    }

    test("AddressabilityReads — a read purged mid-flight is discarded and can't free a newer read") {
        var r = AddressabilityReads<Int>()
        let old = r.request(1)!
        r.purge { $0 == 1 }
        let fresh = r.request(1)!
        try expectEqual(r.resolved(1, generation: old), .discard)
        try expect(r.request(1) == nil, "the stale result must not free the fresh read's slot")
        try expectEqual(r.resolved(1, generation: fresh), .apply)
    }

    test("AddressabilityReads — a read marked stale mid-flight is discarded and re-run once") {
        var r = AddressabilityReads<Int>()
        let g = r.request(1)!
        _ = r.request(2)
        r.markStale { $0 == 1 }
        guard case .rerun(let next) = r.resolved(1, generation: g) else {
            throw Expectation(message: "a stale read must re-run, not apply")
        }
        try expect(next != g)
        try expect(r.request(1) == nil, "the re-run holds the slot")
        try expectEqual(r.resolved(1, generation: next), .apply)
    }

    test("AddressabilityReads — staleness only touches the matching keys") {
        var r = AddressabilityReads<Int>()
        let g = r.request(2)!
        r.markStale { $0 == 1 }
        try expectEqual(r.resolved(2, generation: g), .apply)
    }

    // MARK: - lookup: what callers get without blocking

    test("WindowAddressabilityCache.lookup — an unseen window is pending: addressable, not standard, needs a read") {
        let pid: pid_t = 7_777_730
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let l = WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.0)
        try expectEqual(l.needsRead, true)
        try expectEqual(l.probe.addressable, true)
        try expectEqual(l.probe.isStandard, false,
                        "a window whose subrole is unknown must stay out of tiling until a read confirms it")
    }

    test("WindowAddressabilityCache.lookup — an expired verdict is served as-is while the re-read runs") {
        let pid: pid_t = 7_777_731
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        _ = WindowAddressabilityCache.record(pid: pid, windowID: 1, reading: nil, now: 1000.0)
        let failed = WindowAddressabilityCache.record(pid: pid, windowID: 1, reading: nil, now: 1006.0).probe
        try expectEqual(failed.addressable, false)
        let l = WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1100.0)
        try expectEqual(l.needsRead, true)
        try expectEqual(l.probe.addressable, false, "last known verdict, not a flicker to pending")
        try expectEqual(l.probe.ts, failed.ts)
    }

    test("WindowAddressabilityCache.lookup — a usable verdict needs no read") {
        let pid: pid_t = 7_777_732
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false, now: 1000.0)
        let l = WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 5000.0)
        try expectEqual(l.needsRead, false)
        try expectEqual(l.probe.isStandard, true)
    }

    // MARK: - record: a finished read becomes a verdict

    test("WindowAddressabilityCache.record — a standard reading flips the pending window in") {
        let pid: pid_t = 7_777_733
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let r = WindowAddressabilityCache.record(
            pid: pid, windowID: 1,
            reading: .init(isStandard: true, isMinimized: false), now: 1000.0)
        try expectEqual(r.probe.addressable, true)
        try expectEqual(r.probe.isStandard, true)
        try expectEqual(r.changed, true, "pending → standard changes what Windows.all() reports")
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.1).needsRead, false)
    }

    test("WindowAddressabilityCache.record — a failed read inside grace changes nothing and is not cached") {
        let pid: pid_t = 7_777_734
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        _ = WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.0)
        let r = WindowAddressabilityCache.record(pid: pid, windowID: 1, reading: nil, now: 1000.2)
        try expectEqual(r.changed, false, "grace reports the same pending verdict")
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.3).needsRead, true)
    }

    test("WindowAddressabilityCache.record — grace runs from first sight, not from the first failed read") {
        let pid: pid_t = 7_777_735
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        _ = WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.0)
        let r = WindowAddressabilityCache.record(pid: pid, windowID: 1, reading: nil, now: 1006.0)
        try expectEqual(r.probe.addressable, false)
        try expectEqual(r.changed, true, "pending → unaddressable must push")
    }

    test("WindowAddressabilityCache.record — a failed re-read keeps an established verdict") {
        let pid: pid_t = 7_777_736
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: false, isMinimized: false, now: 1000.0)
        let r = WindowAddressabilityCache.record(pid: pid, windowID: 1, reading: nil, now: 1004.0)
        try expectEqual(r.probe.addressable, true)
        try expectEqual(r.probe.ts, 1004.0, "the failed re-read paces the next one")
        try expectEqual(r.changed, false)
    }
}
