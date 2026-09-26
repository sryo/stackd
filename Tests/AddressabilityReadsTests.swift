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
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false,
                                          traits: .init(isResizable: true, canFullscreen: true), now: 1000.0)
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
            reading: .init(isStandard: true, isMinimized: false,
                           traits: .init(isResizable: true, canFullscreen: true)), now: 1000.0)
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

    // MARK: - traits: resizable / fullscreen-capable

    test("WindowAddressabilityCache.record — a reading's traits land on the verdict, and a trait change pushes") {
        let pid: pid_t = 7_777_737
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false, now: 1000.0)
        let fixed = WindowTraits(isResizable: false, canFullscreen: false)
        let r = WindowAddressabilityCache.record(
            pid: pid, windowID: 1,
            reading: .init(isStandard: true, isMinimized: false, traits: fixed), now: 1000.1)
        try expectEqual(r.probe.traits, fixed)
        try expectEqual(r.changed, true, "traits arriving for a standard window change what Windows.all() reports")
    }

    test("WindowAddressabilityCache.lookup — a standard verdict without traits reads them at once, then backs off on failure") {
        let pid: pid_t = 7_777_738
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false, now: 1000.0)
        try expect(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.0).needsRead,
                   "a create-confirmed window must not wait out a TTL for its traits")
        let failed = WindowAddressabilityCache.record(pid: pid, windowID: 1, reading: nil, now: 1000.1).probe
        try expectEqual(failed.isStandard, true, "a failed trait read keeps the standard verdict")
        try expectEqual(failed.traits, nil)
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.2).needsRead, false,
                        "a failed trait read must not re-read on every pass")
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.7).needsRead, true)
    }

    test("WindowAddressabilityCache.setMinimized keeps the traits") {
        let pid: pid_t = 7_777_739
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let t = WindowTraits(isResizable: true, canFullscreen: false)
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false, traits: t, now: 1000.0)
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: 1, true)
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.1).probe.traits, t)
    }

    test("WindowTraits.from — unreadable attributes fail open, a missing fullscreen button does not") {
        typealias B = WindowTraits.Button
        try expectEqual(WindowTraits.from(sizeSettable: false, fullscreenButton: .enabled),
                        WindowTraits(isResizable: false, canFullscreen: true))
        try expectEqual(WindowTraits.from(sizeSettable: true, fullscreenButton: .absent),
                        WindowTraits(isResizable: true, canFullscreen: false))
        try expectEqual(WindowTraits.from(sizeSettable: true, fullscreenButton: .disabled),
                        WindowTraits(isResizable: true, canFullscreen: false))
        try expectEqual(WindowTraits.from(sizeSettable: nil, fullscreenButton: .unreadable),
                        WindowTraits(isResizable: true, canFullscreen: true),
                        "a timed-out read must not float a window that tiles today")
    }

    test("WindowTraits.fields — the keys Windows.all() adds for a window") {
        let f = WindowTraits(isResizable: false, canFullscreen: true).fields
        try expectEqual(f["isResizable"] as? Bool, false)
        try expectEqual(f["canFullscreen"] as? Bool, true)
    }

    test("WindowAddressabilityCache.confirm keeps traits an earlier read already took") {
        let pid: pid_t = 7_777_740
        defer { WindowAddressabilityCache.invalidate(pid: pid) }
        let t = WindowTraits(isResizable: true, canFullscreen: true)
        _ = WindowAddressabilityCache.record(
            pid: pid, windowID: 1,
            reading: .init(isStandard: true, isMinimized: false, traits: t), now: 1000.0)
        WindowAddressabilityCache.confirm(pid: pid, windowID: 1, isStandard: true, isMinimized: false, now: 1000.5)
        try expectEqual(WindowAddressabilityCache.lookup(pid: pid, windowID: 1, now: 1000.6).probe.traits, t,
                        "a create event landing after the list read must not drop the window from tiling")
    }
}
