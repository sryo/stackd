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

/// Spin the main runloop for the given duration so DispatchQueue.main.asyncAfter
/// work items have a chance to run. Tests on this file use ~20ms delays so a
/// 100ms spin is generous slack without making the suite slow.
private func spinRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

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
        defer { t1.cancel(); t2.cancel(); spinRunLoop(0.05) }

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

        spinRunLoop(0.15)
        try expect(!obs.isActive, "inactive after teardownDelay")
        try expectEqual(obs.teardownCount, 1)
    }

    test("RefCountedObserver: resubscribe inside teardown gap cancels teardown") {
        let obs = StubObserver()
        obs.delay = 0.08
        let t1 = obs.subscribe { }
        t1.cancel()                 // schedules teardown ~80ms out

        spinRunLoop(0.02)           // halfway into the gap
        try expect(obs.isActive, "still active mid-debounce")

        let t2 = obs.subscribe { }  // should cancel the pending teardown
        defer { t2.cancel(); spinRunLoop(0.2) }

        spinRunLoop(0.15)           // well past the original teardown time
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
        defer { t1.cancel(); t2.cancel(); spinRunLoop(0.1) }

        try expect(obs.isActive, "second subscribe succeeded")
        try expectEqual(obs.installCount, 1)
    }

    // MARK: - fireIfChanged (lazy fan-out for poll observers)
    //
    // 2026-06-02: added as the dedup primitive for PrivacyObserver,
    // SensorsObserver, MenubarItemsObserver. Equal hash → no fan-out
    // (skip per-stack jsonify + evaluateJavaScript). Different hash →
    // exactly one fan-out, last hash cached for next compare.

    test("fireIfChanged: equal hash suppresses fan-out") {
        let obs = StubObserver()
        var callCount = 0
        let t = obs.subscribe { callCount += 1 }
        defer { t.cancel(); spinRunLoop(0.05) }
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
        defer { t.cancel(); spinRunLoop(0.05) }
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
        defer { t.cancel(); spinRunLoop(0.05) }
        try expectEqual(callCount, 1)

        obs.fireIfChanged("a", hash: 1)
        obs.fireIfChanged("b", hash: 1)  // same hash, different key → fires
        try expectEqual(callCount, 3)

        obs.fireIfChanged("a", hash: 1)  // a's last was 1, suppressed
        obs.fireIfChanged("b", hash: 1)  // b's last was 1, suppressed
        try expectEqual(callCount, 3, "duplicates under each key remain suppressed")
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
        defer { t.cancel(); spinRunLoop(0.05) }
        try expectEqual(fires, 1, "subscribe primes once")

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            obs.fire()
            sem.signal()
        }
        sem.wait()
        try expectEqual(fires, 1, "off-main fire must not deliver synchronously")

        spinRunLoop(0.1)
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
        defer { t.cancel(); spinRunLoop(0.05) }
        try expectEqual(fires, 1)

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            obs.fireIfChanged("k", hash: 7)
            obs.fireIfChanged("k", hash: 7)   // duplicate — must be suppressed on main
            sem.signal()
        }
        sem.wait()
        spinRunLoop(0.1)
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
        defer { t.cancel(); spinRunLoop(0.05) }
        try expectEqual(fires, 1)

        let group = DispatchGroup()
        for _ in 0..<50 {
            DispatchQueue.global(qos: .utility).async(group: group) {
                obs.fireIfChanged("burst", hash: 99)
            }
        }
        group.wait()
        spinRunLoop(0.15)
        try expectEqual(fires, 2, "50 same-hash calls collapse to a single fire")
    }
}
