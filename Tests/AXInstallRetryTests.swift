import Foundation

// AXInstallRetry (Sources/DataSources/Windows.swift): when to retry the
// frontmost app's AX observer install. A just-launched app is activated
// before it answers AX: AXObserverAddNotification fails with
// kAXErrorCannotComplete for a few hundred ms, and nothing announces when
// it starts answering, so the install is retried on a backoff.

func registerAXInstallRetryTests() {
    test("AXInstallRetry: a failed install schedules a retry that is due") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        guard let next = r.failed(pid: 100) else { throw Expectation(message: "no retry scheduled") }
        try expect(next.after > 0)
        try expect(r.isDue(pid: 100, token: next.token))
    }

    test("AXInstallRetry: delays back off") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        let first = r.failed(pid: 100)
        let second = r.failed(pid: 100)
        try expect(first != nil && second != nil)
        try expect(second!.after > first!.after)
    }

    test("AXInstallRetry: attempts run out") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        var scheduled = 0
        while r.failed(pid: 100) != nil {
            scheduled += 1
            if scheduled > 100 { throw Expectation(message: "retries never run out") }
        }
        try expectEqual(scheduled, AXInstallRetry.delays.count)
    }

    test("AXInstallRetry: the retry window covers a slow launch") {
        // Measured on macOS 27: Calculator, Font Book and Notes started
        // answering 0.25-0.75 s after activation.
        try expect(AXInstallRetry.delays.reduce(0, +) >= 3)
    }

    test("AXInstallRetry: switching to another app cancels the pending retry") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        let next = r.failed(pid: 100)!
        r.reset(to: 200)
        try expect(!r.isDue(pid: 100, token: next.token))
    }

    test("AXInstallRetry: a newer failure supersedes the older retry") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        let older = r.failed(pid: 100)!
        let newer = r.failed(pid: 100)!
        try expect(!r.isDue(pid: 100, token: older.token))
        try expect(r.isDue(pid: 100, token: newer.token))
    }

    test("AXInstallRetry: reactivating the same app starts the backoff over") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        let first = r.failed(pid: 100)!
        _ = r.failed(pid: 100)
        r.reset(to: 100)
        try expectEqual(r.failed(pid: 100)!.after, first.after)
    }

    test("AXInstallRetry: a failure for a pid other than the current one schedules nothing") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        try expect(r.failed(pid: 200) == nil)
    }

    test("AXInstallRetry: reset to nil cancels everything") {
        var r = AXInstallRetry()
        r.reset(to: 100)
        let next = r.failed(pid: 100)!
        r.reset(to: nil)
        try expect(!r.isDue(pid: 100, token: next.token))
        try expect(r.failed(pid: 100) == nil)
    }
}
