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
}
