import Foundation
import CoreGraphics

// Tests for BrightnessCache / BrightnessReader (Display.swift) — the layer
// that keeps external-monitor DDC reads (an I²C round trip plus a 50ms settle
// sleep) off the caller's thread. The pure cache is driven with an explicit
// clock; the reader is driven with a stand-in read function, a fake clock and
// a real serial queue, so nothing here touches IOAVService.

private let displayA: CGDirectDisplayID = 101
private let displayB: CGDirectDisplayID = 102

private final class FakeClock {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
}

private final class ReadLog {
    private let lock = NSLock()
    private var _ids: [CGDirectDisplayID] = []
    private var _threadsWereMain: [Bool] = []
    var ids: [CGDirectDisplayID] { lock.lock(); defer { lock.unlock() }; return _ids }
    var anyOnMain: Bool { lock.lock(); defer { lock.unlock() }; return _threadsWereMain.contains(true) }
    func record(_ id: CGDirectDisplayID) {
        lock.lock(); _ids.append(id); _threadsWereMain.append(Thread.isMainThread); lock.unlock()
    }
}

private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

func registerBrightnessCacheTests() {
    // MARK: - BrightnessCache (pure)

    test("BrightnessCache: an unseen display has no value and asks for one read") {
        var cache = BrightnessCache(ttl: 5)
        let first = cache.lookup(displayA, now: 0)
        try expectEqual(first.value, nil)
        try expectEqual(first.refresh?.displayID, displayA)
    }

    test("BrightnessCache: lookups during an in-flight read do not ask for another") {
        var cache = BrightnessCache(ttl: 5)
        _ = cache.lookup(displayA, now: 0)
        let second = cache.lookup(displayA, now: 0.5)
        try expect(second.refresh == nil, "a read is already in flight")
        try expectEqual(second.value, nil)
    }

    test("BrightnessCache: a completed read is served until the TTL elapses") {
        var cache = BrightnessCache(ttl: 5)
        let ticket = cache.lookup(displayA, now: 0).refresh!
        cache.complete(ticket, value: 0.4, now: 0.1)

        let within = cache.lookup(displayA, now: 4.0)
        try expectEqual(within.value, 0.4)
        try expect(within.refresh == nil, "fresh value needs no read")
    }

    test("BrightnessCache: past the TTL the stale value is still served while a refresh is requested") {
        var cache = BrightnessCache(ttl: 5)
        let ticket = cache.lookup(displayA, now: 0).refresh!
        cache.complete(ticket, value: 0.4, now: 0.1)

        let stale = cache.lookup(displayA, now: 5.2)
        try expectEqual(stale.value, 0.4)
        try expect(stale.refresh != nil, "an expired entry requests a refresh")
        try expect(cache.lookup(displayA, now: 5.3).refresh == nil, "only one refresh at a time")
    }

    test("BrightnessCache: a failed read is recorded as no value") {
        var cache = BrightnessCache(ttl: 5)
        let first = cache.lookup(displayA, now: 0).refresh!
        cache.complete(first, value: 0.4, now: 0.1)
        let second = cache.lookup(displayA, now: 6).refresh!
        cache.complete(second, value: nil, now: 6.1)
        try expectEqual(cache.lookup(displayA, now: 6.2).value, nil)
    }

    test("BrightnessCache: displays are tracked independently") {
        var cache = BrightnessCache(ttl: 5)
        let a = cache.lookup(displayA, now: 0).refresh!
        cache.complete(a, value: 0.3, now: 0.1)
        let b = cache.lookup(displayB, now: 0.2)
        try expectEqual(b.value, nil)
        try expectEqual(b.refresh?.displayID, displayB)
        try expectEqual(cache.lookup(displayA, now: 0.3).value, 0.3)
    }

    test("BrightnessCache: invalidate serves the written value at once and requests a confirming read") {
        var cache = BrightnessCache(ttl: 5)
        let ticket = cache.lookup(displayA, now: 0).refresh!
        cache.complete(ticket, value: 0.4, now: 0.1)

        cache.invalidate(displayA, assuming: 0.8)
        let after = cache.lookup(displayA, now: 0.2)
        try expectEqual(after.value, 0.8)
        try expect(after.refresh != nil, "a set makes the cached read stale even inside the TTL")
    }

    test("BrightnessCache: invalidate without a written value keeps the last value but forces a read") {
        var cache = BrightnessCache(ttl: 5)
        let ticket = cache.lookup(displayA, now: 0).refresh!
        cache.complete(ticket, value: 0.4, now: 0.1)

        cache.invalidate(displayA, assuming: nil)
        let after = cache.lookup(displayA, now: 0.2)
        try expectEqual(after.value, 0.4)
        try expect(after.refresh != nil)
    }

    test("BrightnessCache: a read that was in flight when the value was set cannot overwrite it") {
        var cache = BrightnessCache(ttl: 5)
        let inFlight = cache.lookup(displayA, now: 0).refresh!

        cache.invalidate(displayA, assuming: 0.8)
        cache.complete(inFlight, value: 0.4, now: 0.1)

        try expectEqual(cache.lookup(displayA, now: 0.2).value, 0.8)
    }

    test("BrightnessCache: record marks a live read fresh") {
        var cache = BrightnessCache(ttl: 5)
        _ = cache.lookup(displayA, now: 0)
        cache.record(displayA, value: 0.6, now: 1)
        let l = cache.lookup(displayA, now: 2)
        try expectEqual(l.value, 0.6)
        try expect(l.refresh == nil)
    }

    // MARK: - BrightnessReader (queue + clock)

    test("BrightnessReader: the caller never waits for a slow read") {
        let gate = DispatchSemaphore(value: 0)
        let reader = BrightnessReader(ttl: 5, queue: DispatchQueue(label: "test.brightness.slow")) { _ in
            gate.wait()
            return 0.5
        }
        let start = Date()
        let first = reader.brightness(of: displayA)
        let again = reader.brightness(of: displayA)
        try expect(Date().timeIntervalSince(start) < 0.5, "lookups must return while the read is blocked")
        try expectEqual(first, nil)
        try expectEqual(again, nil)

        gate.signal()
        try expect(waitUntil { reader.brightness(of: displayA) == 0.5 }, "the refreshed value shows up on a later lookup")
    }

    test("BrightnessReader: reads run off the calling thread, once per TTL window") {
        let clock = FakeClock()
        let log = ReadLog()
        let reader = BrightnessReader(ttl: 5, queue: DispatchQueue(label: "test.brightness.ttl"),
                                      clock: { clock.now }) { id in
            log.record(id)
            return 0.25
        }
        _ = reader.brightness(of: displayA)
        try expect(waitUntil { reader.brightness(of: displayA) == 0.25 })
        for _ in 0..<5 { _ = reader.brightness(of: displayA) }
        try expectEqual(log.ids.count, 1, "lookups inside the TTL reuse the read")
        try expect(!log.anyOnMain, "the read must not run on the calling (main) thread")

        clock.advance(6)
        try expectEqual(reader.brightness(of: displayA), 0.25, "the stale value is served meanwhile")
        try expect(waitUntil { log.ids.count == 2 }, "an expired entry triggers one more read")
    }

    test("BrightnessReader: a set shows the written value and then the monitor's own answer") {
        let clock = FakeClock()
        let log = ReadLog()
        let reader = BrightnessReader(ttl: 5, queue: DispatchQueue(label: "test.brightness.set"),
                                      clock: { clock.now }) { id in
            log.record(id)
            return 0.69
        }
        _ = reader.brightness(of: displayA)
        try expect(waitUntil { reader.brightness(of: displayA) == 0.69 })
        let readsBefore = log.ids.count

        reader.invalidate(displayA, assuming: 0.7)
        try expectEqual(reader.brightness(of: displayA), 0.7, "the written value is served immediately")
        try expect(waitUntil { log.ids.count == readsBefore + 1 }, "a confirming read follows the set")
        try expect(waitUntil { reader.brightness(of: displayA) == 0.69 }, "the monitor's reported value replaces the assumption")
    }
}
