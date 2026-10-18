import Foundation

// Tests for RefCountedObserver.swift — the base class every DataSources/
// observer singleton subclasses to get lazy native install + debounced
// teardown. Real subclasses (CGEventTap, CoreAudio, AX, IOKit) can't be
// exercised under test, but the ref-count math + debounce semantics are
// the actual bug surface — wrong install timing churns native resources
// during hot-reload, wrong teardown leaks them indefinitely.
//
// Strategy: subclass RefCountedObserver with a stub that records install
// and teardown calls, controls the install() return (nil for transient
// failure tests), and overrides teardownDelay to a tiny value so the
// debounced async dispatch resolves within a runloop spin instead of
// the production 5s. No native plumbing touched.

// MARK: - Test doubles

private final class StubObserver: RefCountedObserver {
    var installCount = 0
    var teardownCount = 0
    /// If non-nil, override install() to return nil (simulate transient failure)
    /// for the first N calls, then return a real Token.
    var failInstallsRemaining = 0
    /// Override delay; default tiny so teardown lands within a runloop spin.
    var delay: TimeInterval = 0.02

    override var teardownDelay: TimeInterval { delay }

    override func install() -> Token? {
        if failInstallsRemaining > 0 {
            failInstallsRemaining -= 1
            return nil
        }
        installCount += 1
        return Token { [weak self] in self?.teardownCount += 1 }
    }
}

// Most tests here use ~20ms teardown delays, so a 100ms `spin(for:)` is
// generous slack for the DispatchQueue.main.asyncAfter work items without
// making the suite slow.

func registerRefCountedObserverTests() {
    // MARK: - Lifecycle (install / teardown ref-counting)

    test("RefCountedObserver: first subscribe triggers install, isActive flips true") {
        let obs = StubObserver()
        try expectEqual(obs.installCount, 0)
        try expect(!obs.isActive, "should be inactive before any subscribe")

        let t = obs.subscribe { }
        defer { t.cancel() }

        try expectEqual(obs.installCount, 1)
        try expect(obs.isActive, "should be active after first subscribe")
    }

    test("RefCountedObserver: second subscribe shares the install (no double-install)") {
        let obs = StubObserver()
        let t1 = obs.subscribe { }
        let t2 = obs.subscribe { }
        defer { t1.cancel(); t2.cancel(); spin(for: 0.05) }

        try expectEqual(obs.installCount, 1)
    }

    test("RefCountedObserver: subscribe primes the callback immediately") {
        let obs = StubObserver()
        var fires = 0
        let t = obs.subscribe { fires += 1 }
        defer { t.cancel() }

        // Documented contract: cb() is invoked synchronously inside subscribe
        // so stacks render correct initial state before the first system event.
        try expectEqual(fires, 1)
    }

    test("RefCountedObserver: fire() notifies every subscriber") {
        let obs = StubObserver()
        var a = 0, b = 0, c = 0
        let t1 = obs.subscribe { a += 1 }
        let t2 = obs.subscribe { b += 1 }
        let t3 = obs.subscribe { c += 1 }
        defer { t1.cancel(); t2.cancel(); t3.cancel() }

        // After subscribe each cb has been primed exactly once.
        try expectEqual(a, 1); try expectEqual(b, 1); try expectEqual(c, 1)

        obs.fire()
        try expectEqual(a, 2); try expectEqual(b, 2); try expectEqual(c, 2)
    }

    test("RefCountedObserver: a cancelled subscriber no longer receives fire()") {
        let obs = StubObserver()
        var gone = 0, kept = 0
        let t1 = obs.subscribe { gone += 1 }
        let t2 = obs.subscribe { kept += 1 }
        defer { t2.cancel(); spin(for: 0.05) }

        t1.cancel()
        obs.fire()
        try expectEqual(gone, 1, "only the subscribe-time prime")
        try expectEqual(kept, 2)
        try expect(obs.isActive, "one subscriber left, no teardown")
    }

    test("RefCountedObserver: fire() with zero subscribers is a no-op (does not crash)") {
        let obs = StubObserver()
        obs.fire()  // before any subscribe
        try expect(!obs.isActive, "fire() must not install")
        try expectEqual(obs.installCount, 0)
    }

    test("RefCountedObserver: last unsubscribe schedules debounced teardown") {
        let obs = StubObserver()
        obs.delay = 0.02
        let t = obs.subscribe { }
        try expect(obs.isActive, "active after subscribe")

        t.cancel()
        // Teardown is async — still active immediately after cancel.
        try expect(obs.isActive, "still active immediately after last cancel (debounced)")
        try expectEqual(obs.teardownCount, 0)

        spin(timeout: 10) { !obs.isActive }
        try expect(!obs.isActive, "inactive after teardownDelay")
        try expectEqual(obs.teardownCount, 1)

        // After a full teardown the next subscribe installs again.
        let t2 = obs.subscribe { }
        defer { t2.cancel(); spin(for: 0.1) }
        try expectEqual(obs.installCount, 2)
        try expect(obs.isActive)
    }

    test("RefCountedObserver: resubscribe inside teardown gap cancels teardown") {
        let obs = StubObserver()
        obs.delay = 0.3
        let t1 = obs.subscribe { }
        t1.cancel()                 // schedules teardown ~300ms out

        spin(for: 0.02)           // inside the gap
        try expect(obs.isActive, "still active mid-debounce")

        let t2 = obs.subscribe { }  // should cancel the pending teardown
        defer { t2.cancel() }

        spin(for: 0.4)            // well past the original teardown time
        try expect(obs.isActive, "resubscribe must keep observer active")
        try expectEqual(obs.installCount, 1, "should not reinstall when token was still live")
        try expectEqual(obs.teardownCount, 0, "teardown was cancelled, must not fire")
    }

    test("RefCountedObserver: install nil result is retried on next subscribe") {
        let obs = StubObserver()
        obs.failInstallsRemaining = 1   // first install() returns nil

        let t1 = obs.subscribe { }
        try expect(!obs.isActive, "transient failure leaves nativeToken nil")
        try expectEqual(obs.installCount, 0, "failed install did not bump count")

        // Next subscribe retries install — important for the "user grants
        // permission while a stack is already subscribed" path.
        let t2 = obs.subscribe { }
        defer { t1.cancel(); t2.cancel(); spin(for: 0.1) }

        try expect(obs.isActive, "second subscribe succeeded")
        try expectEqual(obs.installCount, 1)
    }

    // MARK: - fireIfChanged (lazy fan-out for poll observers)
    //
    // Equal hash → no fan-out (skip per-stack jsonify + evaluateJavaScript).
    // Different hash → exactly one fan-out, last hash cached for next compare.

    test("fireIfChanged: equal hash suppresses fan-out") {
        let obs = StubObserver()
        var callCount = 0
        let t = obs.subscribe { callCount += 1 }
        defer { t.cancel(); spin(for: 0.05) }
        // subscribe primes once.
        try expectEqual(callCount, 1, "subscribe should prime once")

        obs.fireIfChanged("k", hash: 42)
        try expectEqual(callCount, 2, "first fireIfChanged with new hash fires")

        obs.fireIfChanged("k", hash: 42)
        try expectEqual(callCount, 2, "same hash must not re-fire")

        obs.fireIfChanged("k", hash: 42)
        try expectEqual(callCount, 2, "still same hash, still no fire")
    }

    test("fireIfChanged: changed hash fires exactly once per change") {
        let obs = StubObserver()
        var callCount = 0
        let t = obs.subscribe { callCount += 1 }
        defer { t.cancel(); spin(for: 0.05) }
        try expectEqual(callCount, 1)

        obs.fireIfChanged("k", hash: 1)
        obs.fireIfChanged("k", hash: 2)
        obs.fireIfChanged("k", hash: 3)
        try expectEqual(callCount, 4, "three distinct hashes → three fires")
    }

    test("fireIfChanged: per-key isolation (distinct keys dedup independently)") {
        // The key argument lets a single observer dedup multiple logical
        // streams. Same hash under different keys should still fire.
        let obs = StubObserver()
        var callCount = 0
        let t = obs.subscribe { callCount += 1 }
        defer { t.cancel(); spin(for: 0.05) }
        try expectEqual(callCount, 1)

        obs.fireIfChanged("a", hash: 1)
        obs.fireIfChanged("b", hash: 1)  // same hash, different key → fires
        try expectEqual(callCount, 3)

        obs.fireIfChanged("a", hash: 1)  // a's last was 1, suppressed
        obs.fireIfChanged("b", hash: 1)  // b's last was 1, suppressed
        try expectEqual(callCount, 3, "duplicates under each key remain suppressed")
    }

    // MARK: - perFire (one value per fan-out)

    test("perFire: every subscriber of one fire shares a single compute") {
        let obs = StubObserver()
        var computes = 0
        var seen: [String] = []
        var tokens: [Token] = []
        for _ in 0..<3 {
            tokens.append(obs.subscribe {
                seen.append(obs.perFire("k") { () -> String in computes += 1; return "v\(computes)" })
            })
        }
        defer { for t in tokens { t.cancel() }; spin(for: 0.05) }
        try expectEqual(computes, 3, "each subscribe-time prime computes on its own")

        seen = []
        obs.fire()
        try expectEqual(computes, 4, "one compute for the whole fan-out")
        try expectEqual(seen, ["v4", "v4", "v4"])

        seen = []
        obs.fire()
        try expectEqual(computes, 5, "the next fire computes again")
        try expectEqual(seen, ["v5", "v5", "v5"])
    }

    test("perFire: keys are memoized independently within a fire") {
        let obs = StubObserver()
        var a = 0, b = 0
        let t1 = obs.subscribe { _ = obs.perFire("a") { a += 1 }; _ = obs.perFire("b") { b += 1 } }
        let t2 = obs.subscribe { _ = obs.perFire("a") { a += 1 }; _ = obs.perFire("b") { b += 1 } }
        defer { t1.cancel(); t2.cancel(); spin(for: 0.05) }
        a = 0; b = 0
        obs.fire()
        try expectEqual(a, 1)
        try expectEqual(b, 1)
    }

    test("perFire: outside a fire it always computes, so a later prime is fresh") {
        let obs = StubObserver()
        var computes = 0
        let t1 = obs.subscribe { _ = obs.perFire("k") { computes += 1 } }
        defer { t1.cancel(); spin(for: 0.05) }
        obs.fire()
        computes = 0
        let t2 = obs.subscribe { _ = obs.perFire("k") { computes += 1 } }
        defer { t2.cancel() }
        try expectEqual(computes, 1, "the new subscriber's prime computed instead of reusing the fire's value")
        _ = obs.perFire("k") { computes += 1 }
        try expectEqual(computes, 2)
    }

    test("perFire: a subscriber added during a fire is primed with that fire's value") {
        let obs = StubObserver()
        var computes = 0
        var late: Token?
        var lateSaw: Int?
        var armed = false
        let t1 = obs.subscribe {
            _ = obs.perFire("k") { () -> Int in computes += 1; return computes }
            if armed && late == nil {
                late = obs.subscribe { lateSaw = obs.perFire("k") { () -> Int in computes += 1; return computes } }
            }
        }
        defer { t1.cancel(); late?.cancel(); spin(for: 0.05) }
        armed = true
        obs.fire()
        try expect(late != nil, "the subscriber was added mid-fire")
        try expectEqual(lateSaw, 2, "primed with the fire's shared value")
        try expectEqual(computes, 2, "prime + the fire's single compute")
    }

    test("perFire: a fire nested inside a fire computes afresh") {
        let obs = StubObserver()
        var computes = 0
        var nested = false
        var values: [Int] = []
        let t = obs.subscribe {
            values.append(obs.perFire("k") { () -> Int in computes += 1; return computes })
            if nested { nested = false; obs.fire() }
        }
        defer { t.cancel(); spin(for: 0.05) }
        values = []
        nested = true
        obs.fire()
        try expectEqual(values, [2, 3])
    }

    // MARK: - Off-main trampoline
    //
    // Native callbacks (CoreAudio HAL listeners, IOKit, FSEvents) arrive on
    // arbitrary queues. fire()/fireIfChanged() must confine `subs` /
    // `lastHashByKey` access to the main thread — an off-main call is
    // trampolined, never executed in place.

    test("fire: off-main call is delivered on the main thread") {
        let obs = StubObserver()
        var fires = 0
        var offMainDelivery = false
        let t = obs.subscribe {
            fires += 1
            if !Thread.isMainThread { offMainDelivery = true }
        }
        defer { t.cancel(); spin(for: 0.05) }
        try expectEqual(fires, 1, "subscribe primes once")

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            obs.fire()
            sem.signal()
        }
        sem.wait()
        try expectEqual(fires, 1, "off-main fire must not deliver synchronously")

        drainMainQueue()
        try expectEqual(fires, 2, "trampolined fire delivered after runloop spin")
        try expect(!offMainDelivery, "subscriber must only ever run on main")
    }

    test("fireIfChanged: off-main call dedupes after the trampoline") {
        let obs = StubObserver()
        var fires = 0
        var offMainDelivery = false
        let t = obs.subscribe {
            fires += 1
            if !Thread.isMainThread { offMainDelivery = true }
        }
        defer { t.cancel(); spin(for: 0.05) }
        try expectEqual(fires, 1)

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            obs.fireIfChanged("k", hash: 7)
            obs.fireIfChanged("k", hash: 7)   // duplicate — must be suppressed on main
            sem.signal()
        }
        sem.wait()
        drainMainQueue()
        try expectEqual(fires, 2, "prime + exactly one deduped fire")
        try expect(!offMainDelivery, "subscriber must only ever run on main")
    }

    test("fireIfChanged: concurrent off-main burst neither crashes nor double-fires") {
        // The regression this fences: a poll timer on main and a native
        // listener on a background queue calling fireIfChanged at once,
        // racing on the unlocked hash dictionary.
        let obs = StubObserver()
        var fires = 0
        let t = obs.subscribe { fires += 1 }
        defer { t.cancel(); spin(for: 0.05) }
        try expectEqual(fires, 1)

        let group = DispatchGroup()
        for _ in 0..<50 {
            DispatchQueue.global(qos: .utility).async(group: group) {
                obs.fireIfChanged("burst", hash: 99)
            }
        }
        group.wait()
        drainMainQueue()
        try expectEqual(fires, 2, "50 same-hash calls collapse to a single fire")
    }

    // MARK: - Per-observer teardown delays

    test("RefCountedObserver: base class keeps the 5s hot-reload debounce") {
        final class PlainObserver: RefCountedObserver {
            override func install() -> Token? { nil }
        }
        try expectEqual(PlainObserver().teardownDelay, 5.0)
    }

    test("DisplayLinkObserver: stops the CVDisplayLink 0.5s after the last subscriber, not the 5s default") {
        // The link wakes main on every vsync while installed, so a long
        // idle tail after the last overlay or motion subscriber leaves is
        // pure cost; 0.5s still spans a hot-reload's off/on cycle.
        try expectEqual(DisplayLinkObserver.shared.teardownDelay, 0.5)
    }
}
